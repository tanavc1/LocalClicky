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
    /// Opens each planned URL in Google Chrome when it's installed (the user asked
    /// for "chrome if there"), otherwise the default browser. Still navigation
    /// only — opening a URL can't click, submit, or script the page.
    @discardableResult
    static func execute(_ plan: BrowserPlan) -> Int {
        let chromeURL = chromeApplicationURL()
        var opened = 0
        for action in plan.actions {
            guard let url = URL(string: action.url) else { continue }
            if let chromeURL {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: chromeURL, configuration: configuration)
                opened += 1
            } else if NSWorkspace.shared.open(url) {
                opened += 1
            }
        }
        return opened
    }

    /// The installed Google Chrome bundle, or nil if Chrome isn't present.
    private static func chromeApplicationURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome") {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
