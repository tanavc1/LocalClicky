//
//  AccessibilityTargetApp.swift
//  LocalBrainKit
//
//  Which application the Accessibility harvest should ask. The system-wide hit
//  test can return our own full-screen overlay windows (they sit above every
//  app) or nothing at all, so the harvest asks one application instead: the
//  frontmost one, or, when that is us, the one that owns the topmost visible
//  window at the ink centre. This is the pure part: given the window list,
//  pick the owner. The app side reads the list from the window server.
//

import CoreGraphics
import Foundation

/// One window from the window server's list, in Core Graphics global
/// coordinates (origin top-left of the primary display, y down), the same space
/// as the harvest's probe points.
public struct AccessibilityWindowInfo: Equatable, Sendable {
    public var pid: Int32
    public var bounds: CGRect
    /// The window level layer. 0 is a normal application window.
    public var layer: Int
    public var alpha: Double

    public init(pid: Int32, bounds: CGRect, layer: Int, alpha: Double = 1) {
        self.pid = pid
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }
}

public enum AccessibilityTargetApp {
    /// The pid that owns the topmost normal window containing `point`.
    /// `windows` is ordered front to back, as the window server returns it.
    /// Our own windows, invisible windows and windows above or below the normal
    /// application layer (menu bar, Dock, overlays, desktop) are skipped.
    /// Nil when no such window holds the point.
    public static func owningPid(windows: [AccessibilityWindowInfo],
                                 at point: CGPoint,
                                 excludingPid ownPid: Int32) -> Int32? {
        windows.first { window in
            window.pid != ownPid
                && window.layer == 0
                && window.alpha > 0.01
                && window.bounds.contains(point)
        }?.pid
    }

    /// The pid to probe: the frontmost application when it is not us, otherwise
    /// the owner of the topmost window at `point`. `frontmostPid` is nil when
    /// the system reports none.
    public static func targetPid(frontmostPid: Int32?,
                                 windows: [AccessibilityWindowInfo],
                                 at point: CGPoint,
                                 ownPid: Int32) -> Int32? {
        if let frontmostPid, frontmostPid != ownPid { return frontmostPid }
        return owningPid(windows: windows, at: point, excludingPid: ownPid)
    }

    /// The centre of the box around the probe points, where the window pick is
    /// made. Nil for no points.
    public static func centre(of points: [CGPoint]) -> CGPoint? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }
}
