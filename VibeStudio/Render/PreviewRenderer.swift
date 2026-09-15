import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

/// Per-tick render state computed by the editor view model (all in view-
/// fraction / uv space so the renderer stays dumb).
struct PreviewFrameState {
    var screenUVRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cameraBlurStep = CGSize.zero   // uv offset per tap
    var cameraTaps = 1
    var cursorPosition = CGPoint(x: 0.5, y: 0.5)  // view fraction, y down
    var cursorHeightFraction = 0.045
    var cursorBlurOffsets: [CGSize] = [.zero]     // view fraction, head last
    var layout: CameraLayout = .screenOnly
}

/// Metal preview: video frame from AVPlayerItemVideoOutput, camera transform
/// via texture-coordinate math, velocity-weighted multi-tap motion blur for
/// camera (uv accumulation in shader) and cursor (ghosted trail draws),
/// synthetic vector arrow cursor, webcam bubble / webcam-full layouts.
/// Outer styling (background/padding/corners/shadow) is SwiftUI — hybrid by
/// decision, see DECISIONS.md. Shaders are runtime-compiled from source so no
/// .metal build integration is needed.
final class PreviewRenderer: NSObject {
    static let maxCameraTaps = 16
    static let bubbleWidthFraction: CGFloat = 0.22
    static let bubbleMarginFraction: CGFloat = 0.035

    private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var cursorTexture: MTLTexture?
    private var cursorAspect: CGFloat = 1
    private var screenTexture: MTLTexture?
    private var webcamTexture: MTLTexture?

    private var screenOutput: AVPlayerItemVideoOutput?
    private var webcamOutput: AVPlayerItemVideoOutput?
    private weak var screenPlayer: AVPlayer?
    private weak var webcamPlayer: AVPlayer?
    private weak var view: MTKView?

    var screenVideoSize = CGSize.zero
    var webcamVideoSize = CGSize.zero
    var frameStateProvider: (() -> PreviewFrameState)?

    var isReady: Bool { pipeline != nil }

    override init() {
        super.init()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        self.device = device
        commandQueue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let attachment = descriptor.colorAttachments[0]
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[VibeStudio] Metal pipeline failed: \(error.localizedDescription)")
            return
        }
        cursorTexture = CursorTextureFactory.makeArrowTexture(device: device)
        if let cursorTexture {
            cursorAspect = CGFloat(cursorTexture.width) / CGFloat(cursorTexture.height)
        }
    }

    func attachPlayers(screen: AVPlayer, webcam: AVPlayer?) {
        screenPlayer = screen
        if let item = screen.currentItem {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            screenOutput = output
        }
        webcamPlayer = webcam
        if let item = webcam?.currentItem {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            webcamOutput = output
        }
    }

    func attach(view: MTKView) {
        self.view = view
    }

    @objc func displayLinkTick() {
        pullFrame(from: screenOutput, player: screenPlayer, into: &screenTexture)
        pullFrame(from: webcamOutput, player: webcamPlayer, into: &webcamTexture)
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    private func pullFrame(from output: AVPlayerItemVideoOutput?,
                           player: AVPlayer?,
                           into texture: inout MTLTexture?) {
        guard let output, let player else { return }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        texture = makeTexture(from: pixelBuffer)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
            0, &texture)
        guard status == kCVReturnSuccess, let texture else { return nil }
        return CVMetalTextureGetTexture(texture)
    }

    // MARK: - Drawing

    fileprivate func drawFrame(in view: MTKView) {
        guard let commandQueue, let pipeline,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let state = frameStateProvider?() ?? PreviewFrameState()
        let viewAspect = view.drawableSize.height > 0
            ? view.drawableSize.width / view.drawableSize.height : 16.0 / 9.0

        encoder.setRenderPipelineState(pipeline)

        if let screenTexture, state.layout != .webcamFull {
            encode(encoder, texture: screenTexture,
                   dst: CGRect(x: -1, y: -1, width: 2, height: 2),
                   uv: state.screenUVRect,
                   blurStep: state.cameraBlurStep, alpha: 1, circleMask: false,
                   taps: state.cameraTaps)
        }

        if let webcamTexture, state.layout != .screenOnly {
            let texAspect = CGFloat(webcamTexture.width) / CGFloat(webcamTexture.height)
            switch state.layout {
            case .screenPlusWebcamBubble:
                let dst = bubbleRectNDC(viewAspect: viewAspect)
                encode(encoder, texture: webcamTexture, dst: dst,
                       uv: Self.squareCropUV(texAspect: texAspect),
                       blurStep: .zero, alpha: 1, circleMask: true, taps: 1)
            case .webcamFull:
                encode(encoder, texture: webcamTexture,
                       dst: CGRect(x: -1, y: -1, width: 2, height: 2),
                       uv: Self.aspectFillUV(texAspect: texAspect, viewAspect: viewAspect),
                       blurStep: .zero, alpha: 1, circleMask: false, taps: 1)
            case .screenOnly:
                break
            }
        }

        if let cursorTexture, state.layout != .webcamFull {
            let taps = state.cursorBlurOffsets.count
            for (index, offset) in state.cursorBlurOffsets.enumerated() {
                let isHead = index == taps - 1
                let alpha: Float = isHead ? 1 : Float(0.35 * Double(index + 1) / Double(taps))
                let center = CGPoint(x: state.cursorPosition.x + offset.width,
                                     y: state.cursorPosition.y + offset.height)
                let dst = cursorRectNDC(center: center,
                                        heightFraction: state.cursorHeightFraction,
                                        viewAspect: viewAspect)
                encode(encoder, texture: cursorTexture, dst: dst,
                       uv: CGRect(x: 0, y: 0, width: 1, height: 1),
                       blurStep: .zero, alpha: alpha, circleMask: false, taps: 1)
            }
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private struct DrawUniforms {
        var dstRect: SIMD4<Float>   // NDC origin + size
        var uvRect: SIMD4<Float>
        var blurStep: SIMD2<Float>
        var alpha: Float
        var circleMask: Float
        var taps: Int32
    }

    private func encode(_ encoder: MTLRenderCommandEncoder,
                        texture: MTLTexture,
                        dst: CGRect, uv: CGRect,
                        blurStep: CGSize, alpha: Float,
                        circleMask: Bool, taps: Int) {
        var uniforms = DrawUniforms(
            dstRect: SIMD4(Float(dst.origin.x), Float(dst.origin.y), Float(dst.width), Float(dst.height)),
            uvRect: SIMD4(Float(uv.origin.x), Float(uv.origin.y), Float(uv.width), Float(uv.height)),
            blurStep: SIMD2(Float(blurStep.width), Float(blurStep.height)),
            alpha: alpha,
            circleMask: circleMask ? 1 : 0,
            taps: Int32(min(max(taps, 1), Self.maxCameraTaps)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// View fraction (y down) -> NDC rect for the cursor, preserving the
    /// arrow texture's aspect and anchoring its tip to the cursor position.
    private func cursorRectNDC(center: CGPoint, heightFraction: Double, viewAspect: CGFloat) -> CGRect {
        let heightNDC = heightFraction * 2
        let widthNDC = heightNDC * cursorAspect * viewAspect
        let x = center.x * 2 - 1
        let y = 1 - center.y * 2
        return CGRect(x: x, y: y - heightNDC, width: widthNDC, height: heightNDC)
    }

    private func bubbleRectNDC(viewAspect: CGFloat) -> CGRect {
        let widthNDC = Self.bubbleWidthFraction * 2
        let heightNDC = widthNDC * viewAspect
        let marginX = Self.bubbleMarginFraction * 2
        let marginY = marginX * viewAspect
        return CGRect(x: 1 - marginX - widthNDC, y: -1 + marginY, width: widthNDC, height: heightNDC)
    }

    static func squareCropUV(texAspect: CGFloat) -> CGRect {
        if texAspect >= 1 {
            let w = 1 / texAspect
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        return CGRect(x: 0, y: (1 - texAspect) / 2, width: 1, height: texAspect)
    }

    static func aspectFillUV(texAspect: CGFloat, viewAspect: CGFloat) -> CGRect {
        let uw = min(1, viewAspect / texAspect)
        let uh = min(1, texAspect / viewAspect)
        return CGRect(x: (1 - uw) / 2, y: (1 - uh) / 2, width: uw, height: uh)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DrawUniforms {
        float4 dstRect;
        float4 uvRect;
        float2 blurStep;
        float alpha;
        float circleMask;
        int taps;
    };

    struct VSOut {
        float4 position [[position]];
        float2 uv;
        float2 localUV;
    };

    vertex VSOut previewVertex(uint vid [[vertex_id]], constant DrawUniforms &u [[buffer(0)]]) {
        float2 corners[4] = {{0,0},{1,0},{0,1},{1,1}};
        float2 c = corners[vid];
        VSOut out;
        out.position = float4(u.dstRect.x + c.x * u.dstRect.z,
                              u.dstRect.y + c.y * u.dstRect.w, 0, 1);
        out.uv = u.uvRect.xy + c * u.uvRect.zw;
        out.localUV = c;
        return out;
    }

    fragment float4 previewFragment(VSOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant DrawUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float mask = 1.0;
        if (u.circleMask > 0.5) {
            float d = length(in.localUV - 0.5);
            mask = smoothstep(0.5, 0.47, d);
        }
        float4 sum = float4(0);
        int taps = max(u.taps, 1);
        float center = float(taps - 1) * 0.5;
        for (int i = 0; i < taps; i++) {
            sum += tex.sample(s, in.uv + u.blurStep * (float(i) - center));
        }
        float4 color = sum / float(taps);
        return float4(color.rgb * u.alpha * mask, color.a * u.alpha * mask);
    }
    """
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
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderer.attach(view: view)
        context.coordinator.displayLink = view.displayLink(target: renderer,
                                                           selector: #selector(PreviewRenderer.displayLinkTick))
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.displayLink?.invalidate()
    }

    final class Coordinator {
        var displayLink: CADisplayLink?
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
