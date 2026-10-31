import XCTest
@testable import LocalBrainKit

/// A settable monotonic clock for tests.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ start: UInt64) { value = start }
    func advance(milliseconds: Double) {
        lock.lock(); defer { lock.unlock() }
        value += UInt64(milliseconds * 1_000_000)
    }
    func read() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class TurnTimerTests: XCTestCase {
    private func makeTimer(_ clock: FakeClock) -> TurnTimer {
        TurnTimer(now: { clock.read() }, wallClock: Date(timeIntervalSince1970: 0), turnID: "abc12345")
    }

    func testOffsetsAreMillisecondsSinceKeyDown() {
        let clock = FakeClock(5_000_000_000)
        let timer = makeTimer(clock)
        clock.advance(milliseconds: 1200); timer.mark(.keyUp)
        clock.advance(milliseconds: 300); timer.mark(.transcriptFinal)
        let record = timer.snapshot(outcome: "completed")
        XCTAssertEqual(record.stageMilliseconds[.keyDown], 0)
        XCTAssertEqual(record.stageMilliseconds[.keyUp] ?? -1, 1200, accuracy: 0.001)
        XCTAssertEqual(record.stageMilliseconds[.transcriptFinal] ?? -1, 1500, accuracy: 0.001)
        XCTAssertNil(record.stageMilliseconds[.cursorArrival])
    }

    func testFirstMarkWins() {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        clock.advance(milliseconds: 100); timer.mark(.firstToken)
        clock.advance(milliseconds: 400); timer.mark(.firstToken)
        XCTAssertEqual(timer.snapshot(outcome: "completed").stageMilliseconds[.firstToken] ?? -1, 100, accuracy: 0.001)
    }

    func testReleaseDerivedFigures() {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        clock.advance(milliseconds: 2000); timer.mark(.keyUp)
        clock.advance(milliseconds: 1400); timer.mark(.firstAudio)
        clock.advance(milliseconds: 900); timer.mark(.cursorArrival)
        let record = timer.snapshot(outcome: "completed")
        XCTAssertEqual(record.releaseToFirstAudioMilliseconds ?? -1, 1400, accuracy: 0.001)
        XCTAssertEqual(record.releaseToCursorMilliseconds ?? -1, 2300, accuracy: 0.001)
    }

    func testDerivedFiguresAreNilWithoutBothStages() {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        clock.advance(milliseconds: 10); timer.mark(.keyUp)
        let record = timer.snapshot(outcome: "interrupted")
        XCTAssertNil(record.releaseToFirstAudioMilliseconds)
        XCTAssertNil(record.releaseToCursorMilliseconds)
    }

    func testJSONLineRoundTripsAndHasNoNewline() throws {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        timer.setRoute("screenPoint")
        timer.setModel("studio:dirk")
        timer.setImageSize(width: 1152, height: 720)
        timer.setPointParsed(true)
        timer.setScreenshotCapturedAtPress(true)
        clock.advance(milliseconds: 1000); timer.mark(.keyUp)
        clock.advance(milliseconds: 1000); timer.mark(.firstAudio)
        let line = timer.snapshot(outcome: "completed").jsonLine()

        XCTAssertFalse(line.contains("\n"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["turn_id"] as? String, "abc12345")
        XCTAssertEqual(object["route"] as? String, "screenPoint")
        XCTAssertEqual(object["model"] as? String, "studio:dirk")
        XCTAssertEqual(object["image_width"] as? Int, 1152)
        XCTAssertEqual(object["image_height"] as? Int, 720)
        XCTAssertEqual(object["point_parsed"] as? Bool, true)
        XCTAssertEqual(object["screenshot_at_press"] as? Bool, true)
        XCTAssertEqual(object["outcome"] as? String, "completed")
        let stages = try XCTUnwrap(object["stages_ms"] as? [String: Double])
        XCTAssertEqual(stages["key_up"], 1000)
        XCTAssertEqual(stages["first_audio"], 2000)
        XCTAssertEqual(object["release_to_first_audio_ms"] as? Double, 1000)
    }

    /// The privacy guarantee: the serialised record can only contain these keys,
    /// none of which can carry the question or the answer.
    func testJSONKeysStayWithinTheAllowlist() throws {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        timer.setRoute("text")
        timer.setModel("llama3.2:3b")
        timer.setImageSize(width: 1, height: 1)
        timer.setPointParsed(false)
        timer.setScreenshotCapturedAtPress(false)
        timer.setInk(marks: 2, crop: true)
        timer.setMarks(3)
        for stage in TurnStage.allCases { clock.advance(milliseconds: 1); timer.mark(stage) }
        let line = timer.snapshot(outcome: "completed").jsonLine()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), TurnTimingRecord.allowedJSONKeys)
        let stages = try XCTUnwrap(object["stages_ms"] as? [String: Double])
        XCTAssertEqual(Set(stages.keys), Set(TurnStage.allCases.map(\.rawValue)))
    }

    func testOptionalFieldsAreOmittedWhenUnset() throws {
        let clock = FakeClock(0)
        let line = makeTimer(clock).snapshot(outcome: "error").jsonLine()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertNil(object["route"])
        XCTAssertNil(object["model"])
        XCTAssertNil(object["image_width"])
        XCTAssertNil(object["screenshot_at_press"])
        XCTAssertNil(object["ink_marks"])
        XCTAssertNil(object["ink_crop"])
        XCTAssertNil(object["marks"])
        XCTAssertEqual(object["point_parsed"] as? Bool, false)
    }

    func testInkFieldsAreCountsAndFlagsOnly() throws {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        timer.setInk(marks: 3, crop: false)
        clock.advance(milliseconds: 40); timer.mark(.inkReady)
        clock.advance(milliseconds: 90); timer.mark(.axReady)
        let line = timer.snapshot(outcome: "completed").jsonLine()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["ink_marks"] as? Int, 3)
        XCTAssertEqual(object["ink_crop"] as? Bool, false)
        let stages = try XCTUnwrap(object["stages_ms"] as? [String: Double])
        XCTAssertEqual(stages["ink_ready"], 40)
        XCTAssertEqual(stages["ax_ready"], 130)
    }

    func testMarksAreACountAndFirstMarkIsAStage() throws {
        let clock = FakeClock(0)
        let timer = makeTimer(clock)
        clock.advance(milliseconds: 700); timer.mark(.firstMark)
        clock.advance(milliseconds: 300); timer.mark(.firstMark)
        timer.setMarks(2)
        let line = timer.snapshot(outcome: "completed").jsonLine()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["marks"] as? Int, 2)
        let stages = try XCTUnwrap(object["stages_ms"] as? [String: Double])
        XCTAssertEqual(stages["first_mark"], 700, "a stage keeps its first mark")
        XCTAssertEqual(TurnStage.firstMark.rawValue, "first_mark")
    }

    func testLogAppendsOneLinePerRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-timer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/turn-timings.jsonl")

        let clock = FakeClock(0)
        let record = makeTimer(clock).snapshot(outcome: "completed")
        XCTAssertTrue(TurnTimingLog.append(record, to: file))
        XCTAssertTrue(TurnTimingLog.append(record, to: file))

        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }
}
