import CoreGraphics
import Foundation

/// Projects recorded events (global CG points) into video pixel space using
/// the capture mapping stored in recording-meta.json, including the
/// resolution-cap ratio between native capture pixels and the actual video.
struct EventProjector {
    let mapping: CaptureMapping
    let nativePixelSize: CGSize
    /// video pixels / native capture pixels (1.0 unless resolution was capped).
    let outputScale: CGFloat

    init(meta: RecordingMeta) {
        let scale = CGFloat(meta.scaleFactor)
        switch meta.sourceMode {
        case "window" where meta.windowFrameCGPoints != nil:
            let frame = meta.windowFrameCGPoints ?? meta.displayFrameCGPoints
            mapping = .window(frameCG: frame, scale: scale)
            nativePixelSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        case "area" where meta.sourceRectPixels != nil:
            let rect = meta.sourceRectPixels ?? .zero
            mapping = .area(displayFrameCG: meta.displayFrameCGPoints, sourceRectPixels: rect, scale: scale)
            nativePixelSize = rect.size
        default:
            mapping = .display(frameCG: meta.displayFrameCGPoints, scale: scale)
            nativePixelSize = CGSize(width: meta.displayFrameCGPoints.width * scale,
                                     height: meta.displayFrameCGPoints.height * scale)
        }
        let output = meta.outputPixelSize
        outputScale = nativePixelSize.width > 0 ? output.width / nativePixelSize.width : 1
    }

    func videoPoint(forGlobalCGPoint point: CGPoint) -> CGPoint {
        let native = mapping.videoPixel(forGlobalCGPoint: point)
        return CGPoint(x: native.x * outputScale, y: native.y * outputScale)
    }

    func videoPoint(for event: RecordedEvent) -> CGPoint? {
        guard let x = event.x, let y = event.y else { return nil }
        return videoPoint(forGlobalCGPoint: CGPoint(x: x, y: y))
    }
}
