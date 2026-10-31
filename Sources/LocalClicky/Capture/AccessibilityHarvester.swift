//
//  AccessibilityHarvester.swift
//  LocalClicky
//
//  Reads what is under the user's ink from the system Accessibility tree: the
//  role, title, value, description, link and frame of the elements at a grid of
//  points. It returns plain records; AccessibilitySummary (LocalBrainKit) turns
//  them into the prompt text and drops secure fields.
//
//  A link with no address of its own looks up to three AXParent levels for one
//  (AccessibilityLinkResolver). When the point probes find fewer than two
//  usable elements, the tree is walked from the hit window (else the app's
//  focused window), keeping elements whose frame meets the ink rectangle, at
//  most 200 nodes and 6 levels deep (AccessibilityTreeWalk), inside the same
//  time budget.
//
//  The hit test is asked of one application (the frontmost one that is not us,
//  else the owner of the topmost window at the ink centre); the system-wide
//  element is only the fallback, because it can answer with our own overlay.
//
//  Runs off the main thread with a hard budget: when the budget is up the caller
//  gets whatever was read so far, and a blocked Accessibility call cannot hold
//  the turn. It never prompts for permission; without the Accessibility
//  permission it returns nothing at once. A secure text field is recorded as
//  secure with no text read from it at all.
//

import AppKit
import ApplicationServices
import LocalBrainKit

enum AccessibilityHarvester {
    /// How long a turn will wait for the harvest.
    static let budgetSeconds: Double = 0.2
    /// Per-element limit for a slow or hung app, set on each hit element only.
    private static let perCallTimeoutSeconds: Float = 0.05
    /// A text area's value can be huge; the summary shortens it further.
    private static let maxValueCharacters = 400

    /// `cgPoints` and `inkRect` are in Core Graphics global coordinates (origin
    /// top-left of the primary display, y down), the space the hit test uses.
    /// Without an `inkRect` the tree-walk fallback is skipped.
    static func harvest(atCGPoints cgPoints: [CGPoint],
                        inkRect: CGRect? = nil,
                        budgetSeconds: Double = AccessibilityHarvester.budgetSeconds) async -> [AccessibilityElementRecord] {
        guard !cgPoints.isEmpty, AXIsProcessTrusted() else { return [] }
        let collector = Collector()
        let deadline = Date().addingTimeInterval(budgetSeconds)
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation: continuation, collector: collector)
            DispatchQueue.global(qos: .userInitiated).async {
                probe(cgPoints, inkRect: inkRect, deadline: deadline, collector: collector)
                gate.finish()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budgetSeconds) {
                gate.finish()
            }
        }
    }

    // MARK: - One element's frame

    /// The frame (Core Graphics global coordinates, like `harvest`) of the one
    /// element under `cgPoint`, for the ring and arrow the app draws from a
    /// point (PointThenDraw). Nil without the Accessibility permission, when
    /// nothing answers within `budgetSeconds`, or when the element has no frame.
    /// Reads the frame only: no title, value or other text.
    static func frameOfElement(atCGPoint cgPoint: CGPoint,
                               budgetSeconds: Double = AccessibilityHarvester.budgetSeconds) async -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        return await withCheckedContinuation { continuation in
            let gate = FrameResumeOnce(continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async { gate.finish(hitFrame(atCGPoint: cgPoint)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budgetSeconds) { gate.finish(nil) }
        }
    }

    /// The same two-step hit test as the harvest: the target application first
    /// (the system-wide element can answer with our own overlay), the
    /// system-wide element only when that finds nothing.
    private static func hitFrame(atCGPoint point: CGPoint) -> CGRect? {
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        func frameIfUsable(_ element: AXUIElement) -> CGRect? {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid == ownProcess { return nil }
            AXUIElementSetMessagingTimeout(element, perCallTimeoutSeconds)
            let found = frame(of: element)
            return found == .zero ? nil : found
        }
        var found: AXUIElement?
        if let application = targetApplicationElement(for: [point], ownProcess: ownProcess),
           AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &found) == .success,
           let element = found {
            return frameIfUsable(element)
        }
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &found) == .success,
              let element = found else { return nil }
        return frameIfUsable(element)
    }

    // MARK: - Probing

    private static func probe(_ points: [CGPoint], inkRect: CGRect?, deadline: Date, collector: Collector) {
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        var seen: [AXUIElement] = []

        /// Reads one element once. The same element is hit by many grid
        /// points. Our own overlay windows are not content.
        func take(_ element: AXUIElement) {
            if seen.contains(where: { CFEqual($0, element) }) { return }
            seen.append(element)
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid == ownProcess { return }
            AXUIElementSetMessagingTimeout(element, perCallTimeoutSeconds)
            collector.append(record(for: element))
        }

        // Primary: ask one application. The system-wide hit test can answer
        // with our own full-screen overlay windows, or with nothing at all.
        if let application = targetApplicationElement(for: points, ownProcess: ownProcess) {
            for point in points {
                if Date() >= deadline { return }
                var found: AXUIElement?
                if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &found) == .success,
                   let element = found {
                    take(element)
                }
            }
            // Too little from the points: walk the window's tree for whatever
            // overlaps the ink. The walk shares this probe's deadline.
            if let inkRect,
               AccessibilitySummary.usableCount(collector.snapshot()) < AccessibilityTreeWalk.minimumProbeElements {
                walkWindow(application: application, hits: seen, inkRect: inkRect, deadline: deadline, take: take)
            }
            if !seen.isEmpty { return }
        }

        // Fallback: the system-wide element, only when the app-scoped probe
        // found nothing. No timeout is set on it: that would change the
        // process-wide default for every other Accessibility call in the app.
        // The caller's budget bounds the wait instead.
        let systemWide = AXUIElementCreateSystemWide()
        for point in points {
            if Date() >= deadline { return }
            var found: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &found) == .success,
                  let element = found else { continue }
            take(element)
        }
    }

    /// Fallback: breadth-first over AXChildren from the window the probes hit
    /// (or the app's focused window), handing every element whose frame meets
    /// the ink rectangle to `take`. Bounded by AccessibilityTreeWalk's node and
    /// depth limits and the probe's deadline.
    private static func walkWindow(application: AXUIElement,
                                   hits: [AXUIElement],
                                   inkRect: CGRect,
                                   deadline: Date,
                                   take: (AXUIElement) -> Void) {
        var window: AXUIElement?
        for hit in hits {
            if let found = element(hit, kAXWindowAttribute) { window = found; break }
        }
        if window == nil { window = element(application, kAXFocusedWindowAttribute) }
        guard let window else { return }
        AXUIElementSetMessagingTimeout(window, perCallTimeoutSeconds)

        let result = AccessibilityTreeWalk.collect(
            roots: [window],
            inkRect: inkRect,
            frame: { node in
                AXUIElementSetMessagingTimeout(node, perCallTimeoutSeconds)
                let known = frame(of: node)
                return known == .zero ? nil : known
            },
            children: { node in elements(node, kAXChildrenAttribute) },
            shouldStop: { Date() >= deadline })
        for node in result.nodes {
            if Date() >= deadline { return }
            take(node)
        }
    }

    /// The application element to probe: the frontmost application when it is
    /// not us, otherwise the owner of the topmost on-screen window at the centre
    /// of the probe points (AccessibilityTargetApp picks it from the window
    /// list). The element gets the per-call timeout, so a hung app cannot hold
    /// the hit test past the turn's budget.
    private static func targetApplicationElement(for points: [CGPoint], ownProcess: pid_t) -> AXUIElement? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var windows: [AccessibilityWindowInfo] = []
        if frontmost == nil || frontmost == ownProcess, AccessibilityTargetApp.centre(of: points) != nil {
            windows = onScreenWindows()
        }
        guard let centre = AccessibilityTargetApp.centre(of: points),
              let pid = AccessibilityTargetApp.targetPid(frontmostPid: frontmost,
                                                         windows: windows,
                                                         at: centre,
                                                         ownPid: ownProcess) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, perCallTimeoutSeconds)
        return application
    }

    /// The window server's on-screen windows, front to back, in Core Graphics
    /// global coordinates.
    private static func onScreenWindows() -> [AccessibilityWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return AccessibilityWindowInfo(pid: pid,
                                           bounds: bounds,
                                           layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                                           alpha: entry[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    private static func record(for element: AXUIElement) -> AccessibilityElementRecord {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let frame = frame(of: element)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            // Nothing is read from a secure field, not even its title.
            return AccessibilityElementRecord(role: role, subrole: subrole, isSecure: true, frame: frame)
        }
        var value = string(element, kAXValueAttribute)
        if let long = value, long.count > maxValueCharacters { value = String(long.prefix(maxValueCharacters)) }
        var url = string(element, kAXURLAttribute)
        var linkedFrom: String?
        if role == "AXLink", url == nil {
            let found = AccessibilityLinkResolver.resolve(
                from: element,
                parent: { node in
                    AXUIElementSetMessagingTimeout(node, perCallTimeoutSeconds)
                    return Self.element(node, kAXParentAttribute)
                },
                url: { string($0, kAXURLAttribute) },
                label: { ancestorLabel($0) })
            url = found.url
            linkedFrom = found.linkedFrom
        }
        return AccessibilityElementRecord(role: role,
                                          subrole: subrole,
                                          title: string(element, kAXTitleAttribute),
                                          value: value,
                                          description: string(element, kAXDescriptionAttribute),
                                          url: url,
                                          linkedFrom: linkedFrom,
                                          isSecure: false,
                                          frame: frame)
    }

    /// A short phrase for an ancestor such as `group "Navigation"`, or nil when
    /// it has no title or description. Never read from a secure field.
    private static func ancestorLabel(_ element: AXUIElement) -> String? {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return nil }
        let name = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let name else { return nil }
        let words = AccessibilitySummary.roleWords(AccessibilityElementRecord(role: role, subrole: subrole))
        return "\(words) \"\(name)\""
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else { return [] }
        return list
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        if let text = raw as? String { return text }
        if CFGetTypeID(raw) == CFURLGetTypeID() { return (raw as! URL).absoluteString }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// AXPosition and AXSize are already in Core Graphics top-left coordinates,
    /// which is what AccessibilityElementRecord.frame expects.
    private static func frame(of element: AXUIElement) -> CGRect {
        var positionRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let positionRaw, let sizeRaw,
              CFGetTypeID(positionRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID(),
              AXValueGetValue(positionRaw as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return .zero }
        return CGRect(origin: position, size: size)
    }

    // MARK: - Plumbing

    /// Records gathered so far, readable from the waiting side at any moment.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [AccessibilityElementRecord] = []
        func append(_ record: AccessibilityElementRecord) {
            lock.lock(); defer { lock.unlock() }
            records.append(record)
        }
        func snapshot() -> [AccessibilityElementRecord] {
            lock.lock(); defer { lock.unlock() }
            return records
        }
    }

    /// Resumes the frame lookup exactly once: with the frame or when the budget
    /// runs out, whichever comes first.
    private final class FrameResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CGRect?, Never>?
        init(continuation: CheckedContinuation<CGRect?, Never>) { self.continuation = continuation }
        func finish(_ frame: CGRect?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: frame)
        }
    }

    /// Resumes the caller exactly once: when the probe finishes or the budget
    /// runs out, whichever comes first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[AccessibilityElementRecord], Never>?
        private let collector: Collector
        init(continuation: CheckedContinuation<[AccessibilityElementRecord], Never>, collector: Collector) {
            self.continuation = continuation
            self.collector = collector
        }
        func finish() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: collector.snapshot())
        }
    }
}
