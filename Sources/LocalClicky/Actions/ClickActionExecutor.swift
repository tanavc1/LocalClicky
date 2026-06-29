//
//  ClickActionExecutor.swift
//  LocalClicky
//
//  Posts a real left mouse click at a global screen point. Used when the user
//  explicitly tells LocalClicky to click something ("click the submit button")
//  — the grounding model finds the element, the blue cursor flies to it, and
//  then this performs the actual click.
//
//  Structurally bounded for safety: it can only single-left-click at a point.
//  It can't drag, type, or chain actions, and it only ever runs on an explicit
//  ".screenClick" turn (the user said "click"), never on a describe/point turn.
//

import AppKit
import CoreGraphics

enum ClickActionExecutor {

    /// Synthesizes a left mouse down + up at `cgGlobalPoint` (Core Graphics global
    /// coordinates: origin at the top-left of the primary display, y growing
    /// downward — the same space `CGEvent` and screenshots use). Moves the real
    /// cursor there first so the click lands where the user can see it.
    static func click(atCGGlobalPoint cgGlobalPoint: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Move the hardware cursor to the target so the click is unambiguous.
        CGWarpMouseCursorPosition(cgGlobalPoint)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: cgGlobalPoint, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: cgGlobalPoint, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        // A short gap so the target app registers a real (not zero-length) click.
        usleep(60_000)
        up?.post(tap: .cghidEventTap)
    }

    /// Converts an AppKit global point (bottom-left origin, the space the overlay
    /// and `NSEvent.mouseLocation` use) into the Core Graphics global point a
    /// click needs (top-left origin). The flip is anchored on the primary screen
    /// (`NSScreen.screens.first`), whose AppKit origin is (0,0) and whose top is
    /// CG y = 0 — correct across multi-display setups too.
    static func cgGlobalPoint(fromAppKitGlobalPoint appKitPoint: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }
}
