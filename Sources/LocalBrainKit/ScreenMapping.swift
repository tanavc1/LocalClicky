//
//  ScreenMapping.swift
//  LocalBrainKit
//
//  The geometry that links four coordinate spaces for one captured display:
//    - screenshot pixels  (top-left origin; what the vision model sees)
//    - display-local points (top-left origin; what a per-screen SwiftUI overlay
//      draws in, and what ink samples are recorded in)
//    - global AppKit points (bottom-left origin, spanning all monitors; what
//      NSEvent.mouseLocation and the cursor overlay's window frames use)
//
//  The forward direction (screenshot pixel to global AppKit point) is the exact
//  math of CompanionManager.globalScreenLocation(forImagePoint:in:): clamp to
//  the screenshot, scale by points-per-pixel, flip Y inside the display, then
//  add the display frame origin. The other directions are its inverses.
//

import CoreGraphics
import Foundation

public struct ScreenMapping: Equatable, Sendable {
    /// The display's frame in global AppKit points (bottom-left origin).
    public let displayFrame: CGRect
    public let displayWidthInPoints: Int
    public let displayHeightInPoints: Int
    public let screenshotWidthInPixels: Int
    public let screenshotHeightInPixels: Int

    public init(displayFrame: CGRect,
                displayWidthInPoints: Int,
                displayHeightInPoints: Int,
                screenshotWidthInPixels: Int,
                screenshotHeightInPixels: Int) {
        self.displayFrame = displayFrame
        self.displayWidthInPoints = displayWidthInPoints
        self.displayHeightInPoints = displayHeightInPoints
        self.screenshotWidthInPixels = screenshotWidthInPixels
        self.screenshotHeightInPixels = screenshotHeightInPixels
    }

    private var shotWidth: CGFloat { CGFloat(screenshotWidthInPixels) }
    private var shotHeight: CGFloat { CGFloat(screenshotHeightInPixels) }
    private var displayWidth: CGFloat { CGFloat(displayWidthInPoints) }
    private var displayHeight: CGFloat { CGFloat(displayHeightInPoints) }

    /// The display size in points, for region naming and overlay layout.
    public var displaySizeInPoints: CGSize { CGSize(width: displayWidth, height: displayHeight) }

    // MARK: - Forward

    /// Screenshot pixel (top-left origin) to global AppKit point (bottom-left
    /// origin). Pixels outside the screenshot are clamped onto its edge.
    public func globalPoint(forImagePoint point: CGPoint) -> CGPoint {
        let local = displayLocalPoint(forImagePoint: point)
        let appKitY = displayHeight - local.y
        return CGPoint(x: local.x + displayFrame.origin.x,
                       y: appKitY + displayFrame.origin.y)
    }

    /// Screenshot pixel to display-local point (top-left origin, per screen).
    /// This is also the overlay-local SwiftUI point for that screen. Clamped.
    public func displayLocalPoint(forImagePoint point: CGPoint) -> CGPoint {
        let clampedX = max(0, min(point.x, shotWidth))
        let clampedY = max(0, min(point.y, shotHeight))
        return CGPoint(x: clampedX * (displayWidth / shotWidth),
                       y: clampedY * (displayHeight / shotHeight))
    }

    // MARK: - Inverse

    /// Global AppKit point to screenshot pixel (top-left origin). Not clamped:
    /// a point on another monitor lands outside the screenshot, so check
    /// `containsGlobalPoint` first when that matters.
    public func imagePoint(forGlobalPoint point: CGPoint) -> CGPoint {
        let localX = point.x - displayFrame.origin.x
        let appKitY = point.y - displayFrame.origin.y
        let localY = displayHeight - appKitY
        return imagePoint(forOverlayPoint: CGPoint(x: localX, y: localY))
    }

    /// Overlay-local SwiftUI point (top-left origin, per screen) to screenshot
    /// pixel. Not clamped.
    public func imagePoint(forOverlayPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * (shotWidth / displayWidth),
                y: point.y * (shotHeight / displayHeight))
    }

    /// Screenshot pixel to overlay-local point: an alias of
    /// `displayLocalPoint(forImagePoint:)`, named for the drawing side.
    public func overlayPoint(forImagePoint point: CGPoint) -> CGPoint {
        displayLocalPoint(forImagePoint: point)
    }

    /// Global AppKit point to display-local point (top-left origin, per
    /// screen). Not clamped: a point on another monitor lands outside the
    /// display, so check `containsGlobalPoint` first when that matters.
    public func displayLocalPoint(forGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - displayFrame.origin.x,
                y: displayHeight - (point.y - displayFrame.origin.y))
    }

    /// Display-local point (top-left origin) to global AppKit point.
    public func globalPoint(forDisplayLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + displayFrame.origin.x,
                y: (displayHeight - point.y) + displayFrame.origin.y)
    }

    /// Display-local point to Core Graphics global coordinates: origin at the
    /// top-left of the primary display, y growing downward. This is the space
    /// the Accessibility hit test and CGEvent use. `primaryScreenHeight` is the
    /// primary display's height in points; the flip is anchored on it, which is
    /// correct for displays above, below or beside the primary one.
    public func cgGlobalPoint(forDisplayLocalPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        let appKit = globalPoint(forDisplayLocalPoint: point)
        return CGPoint(x: appKit.x, y: primaryScreenHeight - appKit.y)
    }

    /// Core Graphics global point (origin top-left of the primary display, y
    /// down) to display-local point: the inverse of `cgGlobalPoint`. Not
    /// clamped.
    public func displayLocalPoint(forCGGlobalPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        displayLocalPoint(forGlobalPoint: CGPoint(x: point.x, y: primaryScreenHeight - point.y))
    }

    /// Core Graphics global point to screenshot pixel: the inverse of the model-point-to-screen chain
    /// (`displayLocalPoint(forImagePoint:)` then `cgGlobalPoint`). Not clamped. PointSnap works in Core
    /// Graphics points and hands its result back through this.
    public func imagePoint(forCGGlobalPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        imagePoint(forOverlayPoint: displayLocalPoint(forCGGlobalPoint: point, primaryScreenHeight: primaryScreenHeight))
    }

    /// A Core Graphics global rectangle (an Accessibility frame) as a display-local
    /// rectangle, top-left origin.
    public func displayLocalRect(forCGGlobalRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let topLeft = displayLocalPoint(forCGGlobalPoint: CGPoint(x: rect.minX, y: rect.minY),
                                        primaryScreenHeight: primaryScreenHeight)
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width, height: rect.height)
    }

    /// Whether a global AppKit point falls on this display.
    public func containsGlobalPoint(_ point: CGPoint) -> Bool {
        displayFrame.contains(point)
    }
}
