import XCTest
@testable import VibeStudio

final class PauseCompensatorTests: XCTestCase {
    func testNoPausePassesThrough() {
        let compensator = PauseCompensator()
        XCTAssertEqual(compensator.adjusted(5), 5)
        XCTAssertFalse(compensator.isPaused)
    }

    func testSinglePauseSubtractsGap() {
        var compensator = PauseCompensator()
        XCTAssertEqual(compensator.adjusted(4), 4)
        compensator.pause(at: 5)
        XCTAssertTrue(compensator.isPaused)
        compensator.resume(at: 8)
        XCTAssertFalse(compensator.isPaused)
        // Buffers at t=10 continue at t=7: no 3s jump.
        XCTAssertEqual(compensator.adjusted(10), 7)
        // adjusted() subtracts the offset accumulated so far; buffers that
        // arrived before the pause were already appended with offset 0.
        XCTAssertEqual(compensator.accumulated, 3)
    }

    func testMultiplePausesAccumulate() {
        var compensator = PauseCompensator()
        compensator.pause(at: 5)
        compensator.resume(at: 8)   // +3
        compensator.pause(at: 12)
        compensator.resume(at: 14)  // +2
        XCTAssertEqual(compensator.adjusted(20), 15)
    }

    func testDoublePauseIsIdempotent() {
        var compensator = PauseCompensator()
        compensator.pause(at: 5)
        compensator.pause(at: 6)
        compensator.resume(at: 9)
        XCTAssertEqual(compensator.adjusted(10), 6)
    }

    func testResumeWithoutPauseIsNoOp() {
        var compensator = PauseCompensator()
        compensator.resume(at: 5)
        XCTAssertEqual(compensator.adjusted(10), 10)
    }

    func testSharedClockMediaTime() {
        let clock = SharedPauseClock()
        clock.start(at: 100)
        XCTAssertEqual(clock.mediaTime(105), 5)
        clock.pause(at: 105)
        XCTAssertTrue(clock.isPaused)
        clock.resume(at: 108)
        XCTAssertEqual(clock.mediaTime(110), 7)
        XCTAssertEqual(clock.adjusted(110), 107)
    }
}
