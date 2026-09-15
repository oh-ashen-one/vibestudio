import XCTest
@testable import VibeStudio

final class TimestampMappingTests: XCTestCase {
    // MARK: - Mixed-domain CGEvent timestamps (bug: raw-host t leaks)

    private func eventWithTimestamp(_ ticks: UInt64) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.timestamp = ticks
        return event
    }

    func testMachTickTimestampAccepted() {
        // Timebase on the live machine is 125/3; a genuine mach-tick
        // timestamp converts to ~now and is accepted.
        let now = 41_232.0
        let timebase = Double(EventLogger.hostSeconds(forMachTimestamp: 1_000_000_000))
        let ticks = UInt64(now / timebase * 1e9)
        XCTAssertEqual(EventLogger.sanitizedHostSeconds(for: eventWithTimestamp(ticks), now: now),
                       now, accuracy: 0.01)
    }

    func testNanosecondTimestampFallsBackToNow() {
        // A timestamp already in nanoseconds converts to ~41.7x now (timebase
        // 125/3) and must be rejected in favor of the receipt time.
        let now = 41_232.0
        let nsTicks = UInt64(now * 1e9)
        XCTAssertEqual(EventLogger.sanitizedHostSeconds(for: eventWithTimestamp(nsTicks), now: now),
                       now, accuracy: 1e-9)
    }

    func testZeroTimestampFallsBack() {
        let now = 41_232.0
        XCTAssertEqual(EventLogger.sanitizedHostSeconds(for: eventWithTimestamp(0), now: now),
                       now, accuracy: 1e-9)
    }

    // MARK: - Pause-compensated display time (bug: pill timer ran during pause)

    func testMediaAdjustedFreezesDuringPause() {
        var compensator = PauseCompensator()
        compensator.pause(at: 105)
        // While paused, media time is frozen at the pause point.
        XCTAssertEqual(compensator.mediaAdjusted(105), 105)
        XCTAssertEqual(compensator.mediaAdjusted(110), 105)
        XCTAssertEqual(compensator.mediaAdjusted(135), 105)
        compensator.resume(at: 135)
        XCTAssertEqual(compensator.mediaAdjusted(140), 110)
        // Plain adjusted() (writer path) is unaffected by the freeze logic.
        var second = PauseCompensator()
        second.pause(at: 5)
        XCTAssertEqual(second.adjusted(10), 10)
    }

    func testSharedClockMediaTimeFreezesWhilePaused() {
        let clock = SharedPauseClock()
        clock.start(at: 100)
        clock.pause(at: 105)
        XCTAssertEqual(clock.mediaTime(110), 5, accuracy: 1e-9)
        XCTAssertEqual(clock.mediaTime(135), 5, accuracy: 1e-9)
        clock.resume(at: 135)
        XCTAssertEqual(clock.mediaTime(140), 10, accuracy: 1e-9)
    }
}
