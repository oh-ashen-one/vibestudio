import AppKit
import SwiftUI

/// Centered 3-2-1 overlay shown before capture starts. Completes with `true`
/// when the countdown finishes, `false` when cancelled.
@MainActor
final class CountdownOverlayController {
    fileprivate final class Model: ObservableObject {
        @Published var number = 3
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private let model = Model()
    private var didFinish = false

    func run(completion: @escaping (Bool) -> Void) {
        guard let screen = NSScreen.main else {
            completion(true)
            return
        }
        let size = NSSize(width: 320, height: 320)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless],
                            backing: .buffered,
                            defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, !self.didFinish else { timer.invalidate(); return }
                if self.model.number > 1 {
                    self.model.number -= 1
                } else {
                    timer.invalidate()
                    self.finish(result: true, completion: completion)
                }
            }
        }
    }

    func cancel() {
        finish(result: false, completion: nil)
    }

    private func finish(result: Bool, completion: ((Bool) -> Void)?) {
        guard !didFinish else { return }
        didFinish = true
        timer?.invalidate()
        timer = nil
        panel?.close()
        panel = nil
        completion?(result)
    }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownOverlayController.Model

    var body: some View {
        Text("\(model.number)")
            .font(.system(size: 140, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
