import CoreGraphics
import Foundation

/// §3.4.7 aspect-ratio re-targeting. Applied to keyframes BEFORE camera
/// evaluation: each focus rect is re-derived for the target viewport so the
/// camera follows the action instead of center-cropping. Zoom is preserved
/// (it means "fraction of frame height visible", which is aspect-independent);
/// only the window aspect and clamped center change.
enum AspectRetarget {
    /// Computes the re-targeted window for a camera center/zoom: same height
    /// basis as CameraState.sourceRect, clamped inside the source.
    static func window(center: CGPoint, zoom: Double,
                       sourceSize: CGSize, targetAspect: CGFloat) -> CGRect {
        var height = sourceSize.height / max(zoom, 0.01)
        height = min(height, sourceSize.height)
        let width = min(height * targetAspect, sourceSize.width)
        height = min(width / targetAspect, sourceSize.height)
        var origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        origin.x = min(max(origin.x, 0), sourceSize.width - width)
        origin.y = min(max(origin.y, 0), sourceSize.height - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Re-derives one keyframe's focus rect for the target aspect. Zoom-out
    /// (1x) segments become a centered best-fit reframe; zoomed segments keep
    /// their zoom and re-center the action inside the new viewport.
    static func retarget(_ keyframe: CameraKeyframe,
                         sourceSize: CGSize, targetAspect: CGFloat) -> CameraKeyframe {
        let sourceAspect = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : targetAspect
        guard abs(sourceAspect - targetAspect) > 0.01 else { return keyframe }
        let center = keyframe.zoom > 1
            ? keyframe.center
            : CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let rect = window(center: center, zoom: keyframe.zoom,
                          sourceSize: sourceSize, targetAspect: targetAspect)
        var retargeted = keyframe
        retargeted.focusRect = rect
        return retargeted
    }

    static func keyframes(_ keyframes: [CameraKeyframe],
                          sourceSize: CGSize, targetAspect: CGFloat) -> [CameraKeyframe] {
        keyframes.map { retarget($0, sourceSize: sourceSize, targetAspect: targetAspect) }
    }
}
