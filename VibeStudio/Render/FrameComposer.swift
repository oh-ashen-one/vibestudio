import AppKit
import CoreVideo
import MetalKit

/// Complete per-frame render state shared by preview and export (all in
/// view-fraction / uv space so the compositor stays dumb). Built ONLY by
/// FrameStateBuilder — one code path, so preview and export cannot diverge.
struct CompositorFrameState {
    var screenUVRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cameraBlurStep = CGSize.zero   // uv offset per tap
    var cameraTaps = 1
    var cursorPosition = CGPoint(x: 0.5, y: 0.5)  // video-quad fraction, y down
    var cursorHeightFraction = 0.045
    var cursorBlurOffsets: [CGSize] = [.zero]     // video-quad fraction, head last
    var layout: CameraLayout = .screenOnly
    var paddingFraction = 0.08        // of canvas width
    var cornerRadiusFraction = 0.04   // of video-quad height
    var shadowEnabled = true
    var background: BackgroundSpec = .preset("midnight")
}

/// The single Metal compositor: background (gradient/wallpaper) → drop shadow
/// → screen quad (camera transform via uv, motion blur, rounded corners) →
/// webcam (bubble/full) → synthetic cursor (ghost trail). Used by BOTH the
/// live preview (into an MTKView drawable) and the offline exporter (into an
/// offscreen pixel-buffer texture). Shaders runtime-compiled from source.
final class FrameComposer {
    static let maxCameraTaps = 16
    static let bubbleWidthFraction: CGFloat = 0.22
    static let bubbleMarginFraction: CGFloat = 0.035
    static let shadowFeatherPx: Float = 26
    static let shadowOffsetPx: Float = 14
    static let shadowAlpha: Float = 0.5

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let texturedPipeline: MTLRenderPipelineState
    private let gradientPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let cursorTexture: MTLTexture?
    private var cursorAspect: CGFloat = 1
    private var wallpaperTextures: [String: MTLTexture] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        textureCache = cache
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "composerVertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                let attachment = descriptor.colorAttachments[0]
                attachment?.isBlendingEnabled = true
                attachment?.rgbBlendOperation = .add
                attachment?.alphaBlendOperation = .add
                attachment?.sourceRGBBlendFactor = .one
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            texturedPipeline = try pipeline("texturedFragment")
            gradientPipeline = try pipeline("gradientFragment")
            shadowPipeline = try pipeline("shadowFragment")
        } catch {
            FileHandle.standardError.write(Data(("[VibeStudio/composer] pipeline failed: \(error)\n").utf8))
            return nil
        }
        cursorTexture = CursorTextureFactory.makeArrowTexture(device: device)
        if let cursorTexture {
            cursorAspect = CGFloat(cursorTexture.width) / CGFloat(cursorTexture.height)
        }
    }

    /// Wraps a CVPixelBuffer in a Metal texture. The returned CVMetalTexture
    /// MUST be kept alive by the caller while the MTLTexture is in use.
    func texture(from pixelBuffer: CVPixelBuffer) -> (source: CVMetalTexture, texture: MTLTexture)? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
            0, &texture)
        guard status == kCVReturnSuccess, let texture,
              let mtlTexture = CVMetalTextureGetTexture(texture) else { return nil }
        return (texture, mtlTexture)
    }

    func wallpaperTexture(id: String, kind: Backgrounds.WallpaperKind, startHex: String, endHex: String) -> MTLTexture? {
        if let cached = wallpaperTextures[id] { return cached }
        let image = Backgrounds.cachedWallpaper(kind, size: NSSize(width: 640, height: 400),
                                                startHex: startHex, endHex: endHex)
        guard let texture = Self.makeTexture(from: image, device: device) else { return nil }
        wallpaperTextures[id] = texture
        return texture
    }

    // MARK: - Frame encoding

    /// Encodes one complete styled frame. `outputSize` is the render target's
    /// pixel size; the canvas fills the whole target.
    func encodeFrame(encoder: MTLRenderCommandEncoder,
                     screen: MTLTexture?,
                     webcam: MTLTexture?,
                     state: CompositorFrameState,
                     outputSize: CGSize) {
        let canvasAspect = outputSize.height > 0 ? outputSize.width / outputSize.height : 16.0 / 9.0
        let fullCanvas = CGRect(x: -1, y: -1, width: 2, height: 2)

        // 1. Background
        encodeBackground(encoder: encoder, state: state, dst: fullCanvas)

        // 2. Video quad geometry (padding fraction of canvas width)
        let padX = state.paddingFraction * 2
        let padY = padX * canvasAspect
        let quad = CGRect(x: -1 + padX, y: -1 + padY,
                          width: 2 - 2 * padX, height: 2 - 2 * padY)
        let quadSizePx = CGSize(width: quad.width / 2 * outputSize.width,
                                height: quad.height / 2 * outputSize.height)
        let radiusPx = Float(state.cornerRadiusFraction * quadSizePx.height)

        // 3. Drop shadow behind the video quad
        if state.shadowEnabled {
            let spreadX = CGFloat(Self.shadowFeatherPx) / outputSize.width
            let spreadY = CGFloat(Self.shadowFeatherPx) / outputSize.height
            let offsetY = CGFloat(Self.shadowOffsetPx) / outputSize.height * 2
            let shadowDst = quad.insetBy(dx: -spreadX, dy: -spreadY).offsetBy(dx: 0, dy: -offsetY)
            encodeShadow(encoder: encoder, dst: shadowDst,
                         quadSizePx: CGSize(width: shadowDst.width / 2 * outputSize.width,
                                            height: shadowDst.height / 2 * outputSize.height),
                         radiusPx: radiusPx + Self.shadowFeatherPx)
        }

        // 4. Screen video
        if let screen, state.layout != .webcamFull {
            encode(encoder, texture: screen, pipeline: texturedPipeline,
                   dst: quad, uv: state.screenUVRect,
                   blurStep: state.cameraBlurStep, alpha: 1,
                   circleMask: false, taps: state.cameraTaps,
                   quadSizePx: quadSizePx, radiusPx: radiusPx, roundedMask: true)
        }

        // 5. Webcam
        if let webcam, state.layout != .screenOnly {
            let texAspect = CGFloat(webcam.width) / CGFloat(webcam.height)
            switch state.layout {
            case .screenPlusWebcamBubble:
                let dst = bubbleRectNDC(inside: quad)
                encode(encoder, texture: webcam, pipeline: texturedPipeline,
                       dst: dst, uv: Self.squareCropUV(texAspect: texAspect),
                       blurStep: .zero, alpha: 1, circleMask: true, taps: 1,
                       quadSizePx: quadSizePx, radiusPx: radiusPx, roundedMask: true)
            case .webcamFull:
                encode(encoder, texture: webcam, pipeline: texturedPipeline,
                       dst: quad, uv: Self.aspectFillUV(texAspect: texAspect, viewAspect: canvasAspect),
                       blurStep: .zero, alpha: 1, circleMask: false, taps: 1,
                       quadSizePx: quadSizePx, radiusPx: radiusPx, roundedMask: true)
            case .screenOnly:
                break
            }
        }

        // 6. Synthetic cursor (clipped to the video quad's rounded corners)
        if let cursorTexture, state.layout != .webcamFull {
            let taps = state.cursorBlurOffsets.count
            for (index, offset) in state.cursorBlurOffsets.enumerated() {
                let isHead = index == taps - 1
                let alpha: Float = isHead ? 1 : Float(0.35 * Double(index + 1) / Double(taps))
                let center = CGPoint(x: state.cursorPosition.x + offset.width,
                                     y: state.cursorPosition.y + offset.height)
                let dst = cursorRectNDC(center: center,
                                        heightFraction: state.cursorHeightFraction,
                                        inside: quad, quadSizePx: quadSizePx)
                encode(encoder, texture: cursorTexture, pipeline: texturedPipeline,
                       dst: dst, uv: CGRect(x: 0, y: 0, width: 1, height: 1),
                       blurStep: .zero, alpha: alpha, circleMask: false, taps: 1,
                       quadSizePx: quadSizePx, radiusPx: radiusPx, roundedMask: true)
            }
        }
    }

    // MARK: - Pieces

    private func encodeBackground(encoder: MTLRenderCommandEncoder,
                                  state: CompositorFrameState, dst: CGRect) {
        let spec = state.background
        switch spec {
        case .preset(let id):
            guard let preset = Backgrounds.preset(id: id) else { return }
            if let kind = preset.wallpaper,
               let texture = wallpaperTexture(id: id, kind: kind,
                                              startHex: preset.startHex, endHex: preset.endHex) {
                encode(encoder, texture: texture, pipeline: texturedPipeline,
                       dst: dst, uv: CGRect(x: 0, y: 0, width: 1, height: 1),
                       blurStep: .zero, alpha: 1, circleMask: false, taps: 1,
                       quadSizePx: .zero, radiusPx: 0, roundedMask: false)
            } else {
                encodeGradient(encoder: encoder, dst: dst,
                               startHex: preset.startHex, endHex: preset.endHex)
            }
        case .custom(let startHex, let endHex):
            encodeGradient(encoder: encoder, dst: dst, startHex: startHex, endHex: endHex)
        }
    }

    private func encodeGradient(encoder: MTLRenderCommandEncoder, dst: CGRect, startHex: String, endHex: String) {
        var uniforms = DrawUniforms(dst: dst, uv: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    colorA: Self.float4(Backgrounds.color(hex: startHex)),
                                    colorB: Self.float4(Backgrounds.color(hex: endHex)))
        encoder.setRenderPipelineState(gradientPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeShadow(encoder: MTLRenderCommandEncoder, dst: CGRect,
                              quadSizePx: CGSize, radiusPx: Float) {
        var uniforms = DrawUniforms(dst: dst, uv: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    quadSizePx: quadSizePx, radiusPx: radiusPx)
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    struct DrawUniforms {
        var dstRect: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var blurStep: SIMD2<Float> = .zero
        var alpha: Float = 1
        var circleMask: Float = 0
        var taps: Int32 = 1
        var colorA: SIMD4<Float> = .zero
        var colorB: SIMD4<Float> = .zero
        var quadSizePx: SIMD2<Float> = .zero
        var cornerRadiusPx: Float = 0
        var roundedMask: Float = 0

        init(dst: CGRect, uv: CGRect,
             blurStep: CGSize = .zero, alpha: Float = 1,
             circleMask: Bool = false, taps: Int = 1,
             colorA: SIMD4<Float> = .zero, colorB: SIMD4<Float> = .zero,
             quadSizePx: CGSize = .zero, radiusPx: Float = 0, roundedMask: Bool = false) {
            dstRect = SIMD4(Float(dst.origin.x), Float(dst.origin.y), Float(dst.width), Float(dst.height))
            uvRect = SIMD4(Float(uv.origin.x), Float(uv.origin.y), Float(uv.width), Float(uv.height))
            self.blurStep = SIMD2(Float(blurStep.width), Float(blurStep.height))
            self.alpha = alpha
            self.circleMask = circleMask ? 1 : 0
            self.taps = Int32(min(max(taps, 1), FrameComposer.maxCameraTaps))
            self.colorA = colorA
            self.colorB = colorB
            self.quadSizePx = SIMD2(Float(quadSizePx.width), Float(quadSizePx.height))
            cornerRadiusPx = radiusPx
            self.roundedMask = roundedMask ? 1 : 0
        }
    }

    private func encode(_ encoder: MTLRenderCommandEncoder,
                        texture: MTLTexture,
                        pipeline: MTLRenderPipelineState,
                        dst: CGRect, uv: CGRect,
                        blurStep: CGSize, alpha: Float,
                        circleMask: Bool, taps: Int,
                        quadSizePx: CGSize, radiusPx: Float, roundedMask: Bool) {
        var uniforms = DrawUniforms(dst: dst, uv: uv,
                                    blurStep: blurStep, alpha: alpha,
                                    circleMask: circleMask, taps: taps,
                                    quadSizePx: quadSizePx, radiusPx: radiusPx,
                                    roundedMask: roundedMask)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DrawUniforms>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Cursor tip position is a fraction of the video quad; map to NDC inside
    /// the quad, preserving the arrow texture's aspect.
    private func cursorRectNDC(center: CGPoint, heightFraction: Double,
                               inside quad: CGRect, quadSizePx: CGSize) -> CGRect {
        let heightNDC = heightFraction * quad.height
        let widthNDC = heightNDC * cursorAspect * (quadSizePx.width / max(quadSizePx.height, 1))
        let x = quad.minX + center.x * quad.width
        let y = quad.maxY - center.y * quad.height
        return CGRect(x: x, y: y - heightNDC, width: widthNDC, height: heightNDC)
    }

    private func bubbleRectNDC(inside quad: CGRect) -> CGRect {
        // The quad is a uniform inset of the canvas, so NDC widths and heights
        // scale identically to pixels: a square bubble has
        // height = width * (quad.width / quad.height).
        let widthNDC = Self.bubbleWidthFraction * quad.width
        let heightNDC = widthNDC * (quad.width / max(quad.height, 1))
        let margin = Self.bubbleMarginFraction * quad.width
        return CGRect(x: quad.maxX - margin - widthNDC,
                      y: quad.minY + margin * (quad.width / max(quad.height, 1)),
                      width: widthNDC, height: heightNDC)
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

    static func float4(_ color: NSColor) -> SIMD4<Float> {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return SIMD4(0, 0, 0, 1) }
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
    }

    static func makeTexture(from image: NSImage, device: MTLDevice) -> MTLTexture? {
        let size = NSSize(width: max(Int(image.size.width), 1), height: max(Int(image.size.height), 1))
        let width = Int(size.width), height = Int(size.height)
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGImageByteOrderInfo.order32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        return texture
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
        float4 colorA;
        float4 colorB;
        float2 quadSizePx;
        float cornerRadiusPx;
        float roundedMask;
    };

    struct VSOut {
        float4 position [[position]];
        float2 uv;
        float2 localUV;
    };

    vertex VSOut composerVertex(uint vid [[vertex_id]], constant DrawUniforms &u [[buffer(0)]]) {
        float2 corners[4] = {{0,0},{1,0},{0,1},{1,1}};
        float2 c = corners[vid];
        VSOut out;
        out.position = float4(u.dstRect.x + c.x * u.dstRect.z,
                              u.dstRect.y + c.y * u.dstRect.w, 0, 1);
        out.uv = u.uvRect.xy + c * u.uvRect.zw;
        out.localUV = c;
        return out;
    }

    static float roundedMaskAlpha(float2 localUV, float2 sizePx, float radiusPx) {
        float2 p = (localUV - 0.5) * sizePx;
        float2 b = sizePx * 0.5 - float2(radiusPx);
        float2 q = abs(p) - b;
        float d = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radiusPx;
        return smoothstep(0.75, -0.75, d);
    }

    fragment float4 texturedFragment(VSOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     constant DrawUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float mask = 1.0;
        if (u.circleMask > 0.5) {
            float d = length(in.localUV - 0.5);
            mask *= smoothstep(0.5, 0.47, d);
        }
        if (u.roundedMask > 0.5 && u.quadSizePx.x > 0.0) {
            mask *= roundedMaskAlpha(in.localUV, u.quadSizePx, u.cornerRadiusPx);
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

    fragment float4 gradientFragment(VSOut in [[stage_in]],
                                     constant DrawUniforms &u [[buffer(0)]]) {
        float4 color = mix(u.colorB, u.colorA, in.localUV.y);
        return float4(color.rgb * color.a, color.a);
    }

    fragment float4 shadowFragment(VSOut in [[stage_in]],
                                   constant DrawUniforms &u [[buffer(0)]]) {
        float2 p = (in.localUV - 0.5) * u.quadSizePx;
        float2 b = u.quadSizePx * 0.5 - float2(u.cornerRadiusPx);
        float2 q = abs(p) - b;
        float d = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - u.cornerRadiusPx;
        float alpha = smoothstep(26.0, 0.0, max(d, 0.0)) * 0.5;
        return float4(float3(0.0), 1.0) * alpha;
    }
    """
}
