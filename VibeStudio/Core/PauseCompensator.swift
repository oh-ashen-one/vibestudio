import Foundation

/// Pure timestamp math for pause/resume: while paused, incoming buffers are
/// dropped; on resume the paused wall-time is accumulated and subtracted from
/// subsequent buffer timestamps so the output media has no gap.
struct PauseCompensator: Equatable {
    private(set) var accumulated: Double = 0
    private var pausedAt: Double?

    var isPaused: Bool { pausedAt != nil }

    mutating func pause(at now: Double) {
        if pausedAt == nil { pausedAt = now }
    }

    mutating func resume(at now: Double) {
        if let start = pausedAt {
            accumulated += max(0, now - start)
            pausedAt = nil
        }
    }

    /// Source-time -> media-time adjustment. Times inside an ongoing pause are
    /// expected to be dropped by the caller, not adjusted.
    func adjusted(_ sourceTime: Double) -> Double {
        sourceTime - accumulated
    }
}

/// Thread-safe shared clock in host-clock seconds (CACurrentMediaTime domain,
/// the same domain ScreenCaptureKit / AVCaptureSession buffer PTS use). The
/// screen recorder, webcam recorder and event logger all adjust timestamps
/// through this one instance so every artifact stays aligned across pauses.
final class SharedPauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var compensator = PauseCompensator()
    private var startHostSeconds: Double = 0

    func start(at hostSeconds: Double) {
        lock.lock()
        compensator = PauseCompensator()
        startHostSeconds = hostSeconds
        lock.unlock()
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return compensator.isPaused
    }

    func pause(at hostSeconds: Double) {
        lock.lock()
        compensator.pause(at: hostSeconds)
        lock.unlock()
    }

    func resume(at hostSeconds: Double) {
        lock.lock()
        compensator.resume(at: hostSeconds)
        lock.unlock()
    }

    func adjusted(_ hostSeconds: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return compensator.adjusted(hostSeconds)
    }

    /// Seconds since recording start, excluding paused time.
    func mediaTime(_ hostSeconds: Double) -> Double {
        adjusted(hostSeconds) - startHostSeconds
    }
}
