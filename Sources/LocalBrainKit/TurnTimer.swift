//
//  TurnTimer.swift
//  LocalBrainKit
//
//  A per-turn timing record for the push-to-talk loop: how long each stage took
//  from key down to the cursor landing. It exists so latency work is measured
//  in the real app instead of guessed (the old latency badge only counted
//  stream chunks over wall time).
//
//  Privacy by construction: the record has no field that can hold the question
//  or the answer. It carries stage offsets, the route name, the model name, the
//  screenshot size, and whether a point was parsed. The JSON key set is pinned
//  by a test.
//
//  Every offset is milliseconds since key down, read from a monotonic clock
//  (system uptime), so wall-clock changes cannot distort it.
//

import Foundation

public enum TurnStage: String, CaseIterable, Sendable {
    case keyDown = "key_down"
    case keyUp = "key_up"
    /// The speech engine is running and the mic is open. Measures the cold
    /// engine start that follows a key press.
    case listeningStarted = "listening_started"
    case transcriptFinal = "transcript_final"
    case screenshotReady = "screenshot_ready"
    case requestSent = "request_sent"
    case firstToken = "first_token"
    /// The first spoken clip was handed to the audio player.
    case firstAudio = "first_audio"
    case tagParsed = "tag_parsed"
    case cursorArrival = "cursor_arrival"
    /// The ink is composited onto the screenshot and the close-up is cut.
    case inkReady = "ink_ready"
    /// The Accessibility harvest for the marked area finished (or hit its budget).
    case axReady = "ax_ready"
    /// The first assistant mark (SHAPE or HIGHLIGHT) was handed to the overlay.
    case firstMark = "first_mark"
}

/// An immutable snapshot of one finished (or abandoned) turn.
public struct TurnTimingRecord: Equatable, Sendable {
    public var turnID: String
    /// Wall-clock time of the key press, ISO 8601, for lining a record up with
    /// a day. Never used for any duration.
    public var startedAt: String
    /// Milliseconds since key down, per stage reached.
    public var stageMilliseconds: [TurnStage: Double]
    public var route: String?
    public var model: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var pointParsed: Bool
    /// True when the screenshot used by this turn was captured at key press
    /// rather than after the transcript.
    public var screenshotCapturedAtPress: Bool?
    /// How many marks the user's ink had. Nil on a turn with no ink.
    public var inkMarks: Int?
    /// True when the close-up crop was sent as a second image. Nil on a turn with no ink.
    public var inkCrop: Bool?
    /// How many assistant marks (shapes and highlights) the turn drew. Nil on a
    /// turn that did not draw.
    public var marks: Int?
    /// "completed", "interrupted", or "error".
    public var outcome: String

    /// Key release to the first spoken clip, the "first word" figure.
    public var releaseToFirstAudioMilliseconds: Double? {
        guard let up = stageMilliseconds[.keyUp], let audio = stageMilliseconds[.firstAudio] else { return nil }
        return audio - up
    }

    /// Key release to the cursor landing on the target.
    public var releaseToCursorMilliseconds: Double? {
        guard let up = stageMilliseconds[.keyUp], let arrival = stageMilliseconds[.cursorArrival] else { return nil }
        return arrival - up
    }

    /// The exact set of top-level JSON keys. A test pins this list, so adding a
    /// field (and above all a text field) is a deliberate, reviewed change.
    public static let allowedJSONKeys: Set<String> = [
        "turn_id", "started_at", "stages_ms", "route", "model", "image_width", "image_height",
        "point_parsed", "screenshot_at_press", "outcome", "ink_marks", "ink_crop", "marks",
        "release_to_first_audio_ms", "release_to_cursor_ms",
    ]

    /// One compact JSON object on a single line (no trailing newline), keys sorted.
    public func jsonLine() -> String {
        var object: [String: Any] = [
            "turn_id": turnID,
            "started_at": startedAt,
            "point_parsed": pointParsed,
            "outcome": outcome,
        ]
        var stages: [String: Double] = [:]
        for (stage, value) in stageMilliseconds { stages[stage.rawValue] = Self.rounded(value) }
        object["stages_ms"] = stages
        if let route { object["route"] = route }
        if let model { object["model"] = model }
        if let imageWidth { object["image_width"] = imageWidth }
        if let imageHeight { object["image_height"] = imageHeight }
        if let screenshotCapturedAtPress { object["screenshot_at_press"] = screenshotCapturedAtPress }
        if let inkMarks { object["ink_marks"] = inkMarks }
        if let inkCrop { object["ink_crop"] = inkCrop }
        if let marks { object["marks"] = marks }
        if let value = releaseToFirstAudioMilliseconds { object["release_to_first_audio_ms"] = Self.rounded(value) }
        if let value = releaseToCursorMilliseconds { object["release_to_cursor_ms"] = Self.rounded(value) }

        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return "{}" }
        return line
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// Collects stage marks for one turn. Created at key down; `snapshot` produces
/// the record. Safe to mark from any thread. Each stage keeps its FIRST mark.
public final class TurnTimer: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private let turnID: String
    private let startedAt: String
    private let keyDownNanoseconds: UInt64
    private var marks: [TurnStage: UInt64] = [:]
    private var route: String?
    private var model: String?
    private var imageWidth: Int?
    private var imageHeight: Int?
    private var pointParsed = false
    private var screenshotCapturedAtPress: Bool?
    private var inkMarks: Int?
    private var inkCrop: Bool?
    private var markCount: Int?

    /// - Parameters:
    ///   - now: monotonic nanoseconds. Injected so tests use fixed numbers.
    ///   - wallClock: only for the `started_at` label.
    public init(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallClock: Date = Date(),
        turnID: String = String(UUID().uuidString.prefix(8)).lowercased()
    ) {
        self.now = now
        self.turnID = turnID
        self.startedAt = ISO8601DateFormatter().string(from: wallClock)
        let start = now()
        self.keyDownNanoseconds = start
        self.marks[.keyDown] = start
    }

    /// Records `stage` now, unless it was already recorded.
    public func mark(_ stage: TurnStage) {
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        if marks[stage] == nil { marks[stage] = stamp }
    }

    public func hasMarked(_ stage: TurnStage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return marks[stage] != nil
    }

    public func setRoute(_ route: String) {
        lock.lock(); defer { lock.unlock() }
        self.route = route
    }

    public func setModel(_ model: String) {
        lock.lock(); defer { lock.unlock() }
        self.model = model
    }

    public func setImageSize(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        imageWidth = width
        imageHeight = height
    }

    public func setPointParsed(_ parsed: Bool) {
        lock.lock(); defer { lock.unlock() }
        pointParsed = parsed
    }

    public func setScreenshotCapturedAtPress(_ atPress: Bool) {
        lock.lock(); defer { lock.unlock() }
        screenshotCapturedAtPress = atPress
    }

    /// Counts only: how many marks, and whether the close-up went along.
    public func setInk(marks: Int, crop: Bool) {
        lock.lock(); defer { lock.unlock() }
        inkMarks = marks
        inkCrop = crop
    }

    /// A count only: how many assistant marks the turn drew.
    public func setMarks(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        markCount = count
    }

    public func snapshot(outcome: String) -> TurnTimingRecord {
        lock.lock(); defer { lock.unlock() }
        var offsets: [TurnStage: Double] = [:]
        for (stage, stamp) in marks {
            // A stamp can in principle precede key down only if the clock were
            // not monotonic; clamp so a record never shows a negative offset.
            let delta = stamp >= keyDownNanoseconds ? stamp - keyDownNanoseconds : 0
            offsets[stage] = Double(delta) / 1_000_000
        }
        return TurnTimingRecord(
            turnID: turnID,
            startedAt: startedAt,
            stageMilliseconds: offsets,
            route: route,
            model: model,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            pointParsed: pointParsed,
            screenshotCapturedAtPress: screenshotCapturedAtPress,
            inkMarks: inkMarks,
            inkCrop: inkCrop,
            marks: markCount,
            outcome: outcome
        )
    }
}

/// Appends one JSON line per turn to a local file. Nothing here touches the
/// network.
public enum TurnTimingLog {
    /// `~/Library/Application Support/LocalClicky/turn-timings.jsonl`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LocalClicky", isDirectory: true)
            .appendingPathComponent("turn-timings.jsonl")
    }

    /// Appends the record as one line, creating the directory and file if
    /// needed. Returns false when the write failed; callers only log that.
    @discardableResult
    public static func append(_ record: TurnTimingRecord, to fileURL: URL = defaultFileURL) -> Bool {
        let line = record.jsonLine() + "\n"
        guard let data = line.data(using: .utf8) else { return false }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil) else { return false }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}
