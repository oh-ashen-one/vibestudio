import SwiftUI

/// Focus-rect editor for a selected MANUAL zoom keyframe: dashed rect over
/// the preview (mapped through the current camera window); drag to move the
/// window, drag the bottom-right handle to resize (video aspect preserved,
/// zoom recomputed). Edits write straight into the keyframe → live preview +
/// persistence.
struct ManualZoomEditOverlay: View {
    @ObservedObject var viewModel: EditorViewModel
    let quadRect: CGRect
    let sourceRect: CGRect   // current camera window in video pixels

    private var manualKeyframe: CameraKeyframe? {
        viewModel.keyframes.first { $0.id == viewModel.selectedKeyframeID && $0.isManual }
    }

    private var videoSize: CGSize { viewModel.videoSize }

    var body: some View {
        if let keyframe = manualKeyframe, sourceRect.width > 0, quadRect.width > 0 {
            let rect = viewRect(for: keyframe.focusRect)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(Color.yellow.opacity(0.06))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(keyframe))

                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .position(x: rect.maxX, y: rect.maxY)
                    .gesture(resizeGesture(keyframe))
            }
            .frame(width: quadRect.width, height: quadRect.height)
            .offset(x: quadRect.minX, y: quadRect.minY)
        }
    }

    private func viewRect(for focusRect: CGRect) -> CGRect {
        let scaleX = quadRect.width / sourceRect.width
        let scaleY = quadRect.height / sourceRect.height
        return CGRect(x: (focusRect.minX - sourceRect.minX) * scaleX,
                      y: (focusRect.minY - sourceRect.minY) * scaleY,
                      width: focusRect.width * scaleX,
                      height: focusRect.height * scaleY)
    }

    private func videoDelta(_ translation: CGSize) -> CGSize {
        CGSize(width: translation.width * sourceRect.width / max(quadRect.width, 1),
               height: translation.height * sourceRect.height / max(quadRect.height, 1))
    }

    private func moveGesture(_ keyframe: CameraKeyframe) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            guard let index = viewModel.keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
            let delta = videoDelta(value.translation)
            let original = keyframe.focusRect
            var origin = CGPoint(x: original.minX + delta.width, y: original.minY + delta.height)
            origin.x = min(max(origin.x, 0), videoSize.width - original.width)
            origin.y = min(max(origin.y, 0), videoSize.height - original.height)
            viewModel.keyframes[index].focusRect = CGRect(origin: origin, size: original.size)
        }
    }

    private func resizeGesture(_ keyframe: CameraKeyframe) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            guard let index = viewModel.keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
            let delta = videoDelta(value.translation)
            let original = keyframe.focusRect
            // Video aspect preserved; zoom = fraction of frame height visible.
            let aspect = original.width / max(original.height, 1)
            let newWidth = min(max(original.width + delta.width, videoSize.width / 3), videoSize.width)
            let newHeight = newWidth / aspect
            let zoom = videoSize.height / newHeight
            let center = CGPoint(x: original.midX, y: original.midY)
            var origin = CGPoint(x: center.x - newWidth / 2, y: center.y - newHeight / 2)
            origin.x = min(max(origin.x, 0), videoSize.width - newWidth)
            origin.y = min(max(origin.y, 0), videoSize.height - newHeight)
            viewModel.keyframes[index].focusRect = CGRect(origin: origin,
                                                          size: CGSize(width: newWidth, height: newHeight))
            viewModel.keyframes[index].zoom = min(max(zoom, 1), 1 / AutoZoomEngine.minVisibleWidthFactor)
        }
    }
}
