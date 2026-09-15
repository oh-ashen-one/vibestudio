import SwiftUI

/// Timeline lane showing zoom keyframe blocks. Click selects, drag moves,
/// edge-drag trims, Delete removes, double-click empty space adds a manual
/// zoom. All edits go through the view model so the preview updates live.
struct ZoomTrackView: View {
    @ObservedObject var viewModel: EditorViewModel

    enum TrimEdge { case start, end }

    private enum DragMode { case move, trimStart, trimEnd }
    private struct DragState {
        var id: UUID
        var mode: DragMode
        var original: CameraKeyframe
    }

    @State private var drag: DragState?
    private let edgeWidth: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let duration = max(viewModel.duration, 0.01)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { location in
                        viewModel.addManualKeyframe(at: time(forX: location.x, in: geometry.size.width))
                    }

                ForEach(viewModel.keyframes) { keyframe in
                    block(keyframe, in: geometry.size, duration: duration)
                }

                // Playhead
                let playheadX = viewModel.duration > 0
                    ? viewModel.currentTime / duration * geometry.size.width : 0
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 1)
                    .offset(x: playheadX)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .onKeyPress(.delete) {
            if let id = viewModel.selectedKeyframeID {
                viewModel.deleteKeyframe(id: id)
                return .handled
            }
            return .ignored
        }
    }

    private func time(forX x: CGFloat, in width: CGFloat) -> Double {
        min(max(x / max(width, 1), 0), 1) * max(viewModel.duration, 0.01)
    }

    private func block(_ keyframe: CameraKeyframe, in size: CGSize, duration: Double) -> some View {
        let x = keyframe.tStart / duration * size.width
        let width = max((keyframe.tEnd - keyframe.tStart) / duration * size.width, 6)
        let isSelected = viewModel.selectedKeyframeID == keyframe.id
        return RoundedRectangle(cornerRadius: 4)
            .fill(keyframe.isManual ? Color.orange.opacity(0.75) : Color.accentColor.opacity(0.65))
            .overlay {
                if width > 40 {
                    Text(String(format: "%.1f×", keyframe.zoom))
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.5))
            .frame(width: width, height: size.height - 12)
            .offset(x: x, y: 6)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectedKeyframeID = keyframe.id
            }
            .contextMenu {
                Button("Delete", role: .destructive) {
                    viewModel.deleteKeyframe(id: keyframe.id)
                }
            }
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                if drag == nil || drag?.id != keyframe.id {
                    let localX = value.startLocation.x
                    let mode: DragMode = localX < edgeWidth ? .trimStart
                        : localX > width - edgeWidth ? .trimEnd : .move
                    drag = DragState(id: keyframe.id, mode: mode, original: keyframe)
                    viewModel.selectedKeyframeID = keyframe.id
                }
                guard let drag else { return }
                let dt = value.translation.width / max(size.width, 1) * duration
                switch drag.mode {
                case .move:
                    viewModel.moveKeyframe(id: keyframe.id, toStart: drag.original.tStart + dt)
                case .trimStart:
                    viewModel.trimKeyframe(id: keyframe.id, edge: .start, toTime: drag.original.tStart + dt)
                case .trimEnd:
                    viewModel.trimKeyframe(id: keyframe.id, edge: .end, toTime: drag.original.tEnd + dt)
                }
            }.onEnded { _ in
                drag = nil
            })
    }
}
