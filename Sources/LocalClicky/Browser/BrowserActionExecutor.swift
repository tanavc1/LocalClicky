//
//  BrowserActionExecutor.swift
//  LocalClicky
//
//  Carries out a BrowserPlan by opening each URL in the user's default browser
//  (a new tab). Using NSWorkspace rather than AppleScript keeps this permission-
//  free and browser-agnostic, and — importantly — structurally safe: the only
//  thing this can ever do is *navigate to a URL*. It cannot click, submit forms,
//  send mail, or run page scripts, so every planned action is inherently in the
//  "auto-run safe" category the user chose.
//

import AppKit
import Foundation
import LocalBrainKit

@MainActor
enum BrowserActionExecutor {
    /// Opens each planned URL in the default browser. Returns how many opened.
    @discardableResult
    static func execute(_ plan: BrowserPlan) -> Int {
        var opened = 0
        for action in plan.actions {
            guard let url = URL(string: action.url) else { continue }
            if NSWorkspace.shared.open(url) { opened += 1 }
        }
        return opened
    }
}
