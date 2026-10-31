//
//  TempAppDebugLog.swift
//  LocalClicky
//
//  TEMP debug logger (remove at project end).
//
//  The app-side half of the gateway's debug log, so a test of sketch, clear and pointing turns can be read
//  afterwards. It is on only while the flag file ~/.clicky-gateway/debug.on exists (the same flag the gateway
//  logger reads, so `clicky-gateway debug off` turns both off) and appends one JSON line per event to
//  ~/.clicky-gateway/debug-app-turns.jsonl, created with mode 0600. Off, it does nothing and costs one file
//  existence check per call.
//
//  It never records an image or screen content: the transcript, the figure, the point and the label the model
//  gave, and the label of the element or title of the window the snap matched. Every call site carries the
//  comment "TEMP debug logger (remove at project end)"; remove the call sites, then this file. README, section
//  "Temporary app debug log", says how.
//

import CoreGraphics
import Foundation

enum TempAppDebugLog {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky-gateway")
    private static let flagPath = directory.appendingPathComponent("debug.on").path
    private static let logPath = directory.appendingPathComponent("debug-app-turns.jsonl").path
    private static let queue = DispatchQueue(label: "localclicky.temp-app-debug-log")

    static var isOn: Bool { FileManager.default.fileExists(atPath: flagPath) }

    /// Appends one line: `ts`, `event`, then `fields`. Values must be JSON types (String, Int, Double, Bool,
    /// arrays and dictionaries of them); anything else is dropped from the line.
    static func append(_ event: String, _ fields: [String: Any]) {
        guard isOn else { return }
        var line = fields.filter { JSONSerialization.isValidJSONObject([$0.value]) }
        line["ts"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                 formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        line["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        queue.async {
            let manager = FileManager.default
            if !manager.fileExists(atPath: logPath) {
                manager.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    /// A point as [x, y], one decimal.
    static func point(_ point: CGPoint) -> [Double] {
        [(Double(point.x) * 10).rounded() / 10, (Double(point.y) * 10).rounded() / 10]
    }
}
