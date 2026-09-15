import CoreGraphics

/// Maps a captured-content description (recorded into recording-meta.json) to a
/// projection of global CG points into video pixel space.
enum CaptureMapping: Equatable {
    /// frame: SCDisplay frame in global CG points (top-left origin).
    case display(frameCG: CGRect, scale: CGFloat)
    /// frame: SCWindow frame in global CG points at record time.
    case window(frameCG: CGRect, scale: CGFloat)
    /// Area mode: display frame in CG points plus the source rect in pixels.
    case area(displayFrameCG: CGRect, sourceRectPixels: CGRect, scale: CGFloat)

    func videoPixel(forGlobalCGPoint point: CGPoint) -> CGPoint {
        switch self {
        case let .display(frame, scale), let .window(frame, scale):
            return CGPoint(x: (point.x - frame.minX) * scale,
                           y: (point.y - frame.minY) * scale)
        case let .area(displayFrame, sourceRect, scale):
            return CGPoint(x: (point.x - displayFrame.minX) * scale - sourceRect.minX,
                           y: (point.y - displayFrame.minY) * scale - sourceRect.minY)
        }
    }
}

/// Conversions between the three coordinate spaces used by the recorder:
/// - CG global event space: points, top-left origin of the primary display.
/// - AppKit screen space: points, bottom-left origin of the primary display.
/// - ScreenCaptureKit pixel space: pixels, top-left origin of the captured content.
///
/// All functions take the primary display height (and scale) as parameters so
/// they are pure and unit-testable without a window server.
enum CoordinateMapper {
    static func appKitPointToCG(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func cgPointToAppKit(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func appKitRectToCG(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    static func cgRectToAppKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Area mode: dragged rect (global AppKit points) -> SCStreamConfiguration.sourceRect
    /// (pixels, relative to the display's top-left origin).
    static func areaSourceRectPixels(dragRectAppKitGlobal drag: CGRect,
                                     displayFrameCG: CGRect,
                                     scale: CGFloat,
                                     primaryHeight: CGFloat) -> CGRect {
        let cg = appKitRectToCG(drag, primaryHeight: primaryHeight)
        return CGRect(x: (cg.minX - displayFrameCG.minX) * scale,
                      y: (cg.minY - displayFrameCG.minY) * scale,
                      width: cg.width * scale,
                      height: cg.height * scale)
    }

    static func nativePixelSize(pointSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// Applies the resolution cap (height-based) and rounds to even pixel counts
    /// as required by H.264.
    static func cappedPixelSize(native: CGSize, cap: RecordingSettings.ResolutionCap) -> CGSize {
        let capHeight: CGFloat
        switch cap {
        case .native: capHeight = .greatestFiniteMagnitude
        case .p1080: capHeight = 1080
        case .p4k: capHeight = 2160
        }
        var size = native
        if size.height > capHeight, size.height > 0 {
            let factor = capHeight / size.height
            size = CGSize(width: size.width * factor, height: capHeight)
        }
        func even(_ value: CGFloat) -> Int {
            let rounded = Int(value.rounded())
            return rounded - (rounded % 2)
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}
