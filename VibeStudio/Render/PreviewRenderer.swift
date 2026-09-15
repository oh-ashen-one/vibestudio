import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

/// Live preview driver: owns the AVPlayerItemVideoOutputs, the vsync display
/// link and the MTKView, and delegates ALL drawing to the shared
/// FrameComposer (the same code the exporter renders with).
final class PreviewRenderer: NSObject {
    /// Unbuffered diagnostics — print() is block-buffered when stdout is
    /// redirected, so anything meant for live debugging goes to stderr.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[VibeStudio/render] \(message)\n").utf8))
    }

    private(set) var composer: FrameComposer?
    private var screenTexture: MTLTexture?
    private var screenTextureSource: CVMetalTexture?
    private var webcamTexture: MTLTexture?
    private var webcamTextureSource: CVMetalTexture?
    private var didLogFirstScreenFrame = false
    private var didLogFirstWebcamFrame = false
    private var tickCount = 0
    private var pullAttempts = 0
    private var pullHasNew = 0
    private var pullCopied = 0
    private var drawCount = 0
    private var drawWithScreenTexture = 0

    private var screenOutput: AVPlayerItemVideoOutput?
    private var webcamOutput: AVPlayerItemVideoOutput?
    private weak var screenPlayer: AVPlayer?
    private weak var webcamPlayer: AVPlayer?
    private weak var view: MTKView?

    var screenVideoSize = CGSize.zero
    var webcamVideoSize = CGSize.zero
    var frameStateProvider: (() -> CompositorFrameState)?

    var device: MTLDevice? { composer?.device }
    var isReady: Bool { composer != nil }

    override init() {
        super.init()
        composer = FrameComposer()
    }

    func attachPlayers(screen: AVPlayer, webcam: AVPlayer?) {
        screenPlayer = screen
        if let item = screen.currentItem {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            screenOutput = output
            Self.log("attachPlayers: screen output attached (outputs=\(item.outputs.count))")
        } else {
            Self.log("attachPlayers: screen player has NO currentItem — no frames will be pulled")
        }
        webcamPlayer = webcam
        if let item = webcam?.currentItem {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            webcamOutput = output
            Self.log("attachPlayers: webcam output attached")
        }
    }

    func attach(view: MTKView) {
        self.view = view
        Self.log("attach(view:) device=\(view.device != nil)")
    }

    @objc func displayLinkTick() {
        tickCount += 1
        pullScreenFrame()
        pullWebcamFrame()
        view?.setNeedsDisplay(view?.bounds ?? .zero)
        if tickCount == 120 || tickCount % 600 == 0 {
            let healthy = pullCopied > 0 && drawWithScreenTexture > 0
            if !healthy {
                Self.log("UNHEALTHY ticks=\(tickCount) pullAttempts=\(pullAttempts) hasNew=\(pullHasNew) copied=\(pullCopied) draws=\(drawCount) drawsWithTexture=\(drawWithScreenTexture) screenTexture=\(screenTexture != nil)")
            }
        }
    }

    private func pullScreenFrame() {
        guard let output = screenOutput, let player = screenPlayer else { return }
        pullAttempts += 1
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        pullHasNew += 1
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        pullCopied += 1
        guard let wrapped = composer?.texture(from: pixelBuffer) else { return }
        screenTextureSource = wrapped.source
        screenTexture = wrapped.texture
        if !didLogFirstScreenFrame {
            didLogFirstScreenFrame = true
            Self.log("first screen frame pulled t=\(time.seconds)s")
        }
    }

    private func pullWebcamFrame() {
        guard let output = webcamOutput, let player = webcamPlayer else { return }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        guard let wrapped = composer?.texture(from: pixelBuffer) else { return }
        webcamTextureSource = wrapped.source
        webcamTexture = wrapped.texture
        if !didLogFirstWebcamFrame {
            didLogFirstWebcamFrame = true
            Self.log("first webcam frame pulled t=\(time.seconds)s")
        }
    }

    // MARK: - Drawing

    fileprivate func drawFrame(in view: MTKView) {
        guard let composer,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = composer.commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let state = frameStateProvider?() ?? CompositorFrameState()
        drawCount += 1
        if screenTexture != nil { drawWithScreenTexture += 1 }
        composer.encodeFrame(encoder: encoder,
                             screen: screenTexture,
                             webcam: webcamTexture,
                             state: state,
                             outputSize: view.drawableSize)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

extension PreviewRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        drawFrame(in: view)
    }
}

/// SwiftUI wrapper with a CADisplayLink driving frame pulls at vsync.
struct PreviewMetalView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = PreviewMTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderer.attach(view: view)
        // NB: NSView.displayLink(target:selector:) only works once the view is
        // in a window — in makeNSView it returns nil/never fires, which left
        // the pull loop dead (black video). Install it from viewDidMoveToWindow
        // and register it with the run loop explicitly.
        view.onMovedToWindow = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, coordinator.displayLink == nil else { return }
            let link = view.displayLink(target: renderer,
                                        selector: #selector(PreviewRenderer.displayLinkTick))
            link.add(to: .main, forMode: .common)
            coordinator.displayLink = link
            PreviewRenderer.log("displayLink installed")
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.displayLink?.invalidate()
        (nsView as? PreviewMTKView)?.onMovedToWindow = nil
    }

    final class Coordinator {
        var displayLink: CADisplayLink?
    }
}

private final class PreviewMTKView: MTKView {
    var onMovedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }
}

/// Draws a vector arrow cursor into a 256x256 BGRA texture (premultiplied).
enum CursorTextureFactory {
    static let textureSize = 256

    static func makeArrowTexture(device: MTLDevice) -> MTLTexture? {
        let size = textureSize
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGImageByteOrderInfo.order32Little.rawValue) else { return nil }

        let margin: CGFloat = 20
        let scale = (CGFloat(size) - margin * 2) / 24
        context.translateBy(x: margin, y: margin)
        context.scaleBy(x: scale, y: scale)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 19))
        path.addLine(to: CGPoint(x: 5.4, y: 14.2))
        path.addLine(to: CGPoint(x: 9.2, y: 22.4))
        path.addLine(to: CGPoint(x: 12.3, y: 20.9))
        path.addLine(to: CGPoint(x: 8.7, y: 12.9))
        path.addLine(to: CGPoint(x: 14.8, y: 12.9))
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(1.1)
        context.setLineJoin(.round)
        context.strokePath()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                        mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        return texture
    }
}
