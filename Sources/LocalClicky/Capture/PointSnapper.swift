//
//  PointSnapper.swift
//  LocalClicky
//
//  The input and output half of snapping the model's point (the decisions are PointSnap, in LocalBrainKit).
//  Window requests read the window server's on-screen windows; control requests ask the Accessibility tree
//  about a few points around the model's. Both are bounded: the window list is one call, the Accessibility
//  reads share PointSnap.budgetSeconds (AccessibilityHarvester's deadline), so a turn waits about 150 ms at
//  most. Without the Accessibility permission, or with no match, the model's point is returned as it was.
//
//  Coordinates: the model's point arrives in screenshot pixels. It is mapped to Core Graphics global points
//  (top-left of the primary display, y down), the space of Accessibility frames and window bounds, snapped
//  there, and mapped back to pixels. The map is ScreenMapping's, and the cursor takes pixels as before.
//

import AppKit
import ApplicationServices
import LocalBrainKit

enum PointSnapper {
    struct Outcome {
        /// The point to fly the cursor to, in screenshot pixels.
        let imagePoint: CGPoint
        let result: PointSnapResult
        /// The snapped point in Core Graphics global points, nil when nothing was snapped.
        let snappedScreenPoint: CGPoint?
    }

    /// `primaryHeight` is the primary screen's height in points, read by the caller on the main actor
    /// (NSScreen is not read from here).
    static func snap(imagePoint: CGPoint, label: String?, object: String?, namesWindow: Bool, mapping: ScreenMapping,
                     primaryHeight: CGFloat) async -> Outcome {
        let modelPoint = mapping.cgGlobalPoint(forDisplayLocalPoint: mapping.displayLocalPoint(forImagePoint: imagePoint),
                                               primaryScreenHeight: primaryHeight)
        let displayRect = CGRect(x: mapping.displayFrame.minX, y: primaryHeight - mapping.displayFrame.maxY,
                                 width: mapping.displayFrame.width, height: mapping.displayFrame.height)
        let result: PointSnapResult
        if namesWindow {
            result = PointSnap.windowSnap(modelPoint: modelPoint, object: object, label: label,
                                          windows: onScreenWindows(on: displayRect), displayTop: displayRect.minY)
                ?? PointSnapResult(point: modelPoint, kind: .none, matchedLabel: nil)
        } else {
            result = await controlSnap(modelPoint: modelPoint, label: label)
        }
        guard result.kind != .none else { return Outcome(imagePoint: imagePoint, result: result, snappedScreenPoint: nil) }
        // Stay on the display the screenshot was taken of.
        let kept = CGPoint(x: min(max(result.point.x, displayRect.minX), displayRect.maxX),
                           y: min(max(result.point.y, displayRect.minY), displayRect.maxY))
        return Outcome(imagePoint: mapping.imagePoint(forCGGlobalPoint: kept, primaryScreenHeight: primaryHeight),
                       result: PointSnapResult(point: kept, kind: result.kind, matchedLabel: result.matchedLabel),
                       snappedScreenPoint: kept)
    }

    // MARK: - Control

    private static func controlSnap(modelPoint: CGPoint, label: String?) async -> PointSnapResult {
        let unchanged = PointSnapResult(point: modelPoint, kind: .none, matchedLabel: nil)
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return unchanged }
        let radius = PointSnap.searchRadius
        let records = await AccessibilityHarvester.harvest(
            atCGPoints: PointSnap.probePoints(around: modelPoint, radius: radius),
            inkRect: CGRect(x: modelPoint.x - radius, y: modelPoint.y - radius, width: 2 * radius, height: 2 * radius),
            budgetSeconds: PointSnap.budgetSeconds)
        let candidates = PointSnap.candidates(from: records)
        return PointSnap.controlSnap(modelPoint: modelPoint, label: label, candidates: candidates)
    }

    // MARK: - Window

    /// The normal application windows on the display, front to back, in Core Graphics global points. Our own
    /// windows (the overlays), the menu bar and the Dock (layers above 0), invisible windows and the desktop
    /// are left out, the same filter as AccessibilityTargetApp.owningPid.
    private static func onScreenWindows(on displayRect: CGRect) -> [SnapWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.intersects(displayRect) else { return nil }
            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SnapWindow(title: title, owner: entry[kCGWindowOwnerName as String] as? String, frame: bounds)
        }
    }
}
