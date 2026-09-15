import SwiftUI

/// Minimal In/Out trim bar: two draggable handles constraining the export
/// range. Stored in EditorSettings (project.json) — Phase 4 implements trim
/// only; speed-up segments are deferred to Phase 5.
struct TrimRangeView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        GeometryReader { geometry in
            let duration = max(viewModel.duration, 0.01)
            let start = viewModel.settings.trimStart ?? 0
            let end = viewModel.settings.trimEnd ?? viewModel.duration
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))

                // Active range highlight
                let startX = start / duration * geometry.size.width
                let endX = end / duration * geometry.size.width
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: max(endX - startX, 4))
                    .offset(x: startX)

                handle(x: startX, height: geometry.size.height)
                    .gesture(drag(width: geometry.size.width, duration: duration, isStart: true))
                handle(x: endX, height: geometry.size.height)
                    .gesture(drag(width: geometry.size.width, duration: duration, isStart: false))
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { _ in
                viewModel.settings.trimStart = nil
                viewModel.settings.trimEnd = nil
            }
            .help("Drag handles to set export In/Out · double-click to reset")
        }
    }

    private func handle(x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 8)
            .frame(height: height)
            .offset(x: x - 4)
    }

    private func drag(width: CGFloat, duration: Double, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            let time = min(max(value.location.x / max(width, 1), 0), 1) * duration
            if isStart {
                let limit = (viewModel.settings.trimEnd ?? viewModel.duration) - 0.2
                viewModel.settings.trimStart = min(max(time, 0), max(limit, 0))
            } else {
                let limit = (viewModel.settings.trimStart ?? 0) + 0.2
                viewModel.settings.trimEnd = max(min(time, duration), limit)
            }
        }
    }
}
