//
//  LocalAppLauncher.swift
//  LocalClicky
//
//  Resolves a spoken app name ("notes", "the activity monitor", "vs code") to an
//  application that is actually installed on this Mac, and opens it. Like the
//  browser executor this is intentionally a *navigation-only* capability: the
//  only thing it can do is bring an installed app to the foreground (the same as
//  the user double-clicking it in Finder). It cannot install, delete, or modify
//  anything, so it stays firmly in the "auto-run safe" category.
//
//  Resolution is deterministic: Launch Services by display name (which also finds
//  system apps like Safari that live behind the read-only/Cryptex firmlink), with
//  a fuzzy scan of the standard Applications folders as a fallback for partial
//  names. The spoken-name → app-name matching (incl. shorthands like "vs code")
//  lives in LocalBrainKit.AppCommandPlanner so it's unit-tested. Either way it
//  matches a real installed app or cleanly reports that it didn't.
//

import AppKit
import Foundation
import LocalBrainKit

@MainActor
enum LocalAppLauncher {

    /// Standard places macOS keeps apps. We scan these (and one level of
    /// subfolders, to catch things like /Applications/Utilities) for *.app.
    private static let searchRoots: [URL] = {
        var roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent("Applications"))
        return roots
    }()

    /// Cached index of installed apps (lowercased display name → bundle URL).
    /// Apps rarely change during a session; we refresh lazily after a few minutes.
    private static var cachedIndex: [String: URL] = [:]
    private static var cacheBuiltAt: Date = .distantPast

    /// Launches the app that best matches `spokenName`. Returns the resolved
    /// app's display name on success, or nil if no installed app matched (so the
    /// caller can fall back, e.g. to a web search, or say it couldn't find it).
    @discardableResult
    static func launchApp(named spokenName: String) -> String? {
        guard let url = resolveAppURL(for: spokenName) else { return nil }
        let displayName = url.deletingPathExtension().lastPathComponent
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { print("⚠️ LocalAppLauncher: failed to open \(displayName): \(error)") }
        }
        return displayName
    }

    /// True if some installed app matches the spoken name. Lets the dispatcher
    /// decide between launching an app and falling back, without launching twice.
    static func canResolve(_ spokenName: String) -> Bool {
        resolveAppURL(for: spokenName) != nil
    }

    // MARK: - Resolution

    static func resolveAppURL(for spokenName: String) -> URL? {
        let query = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        // Resolve common shorthands ("vs code" → "visual studio code") up front.
        let aliased = AppCommandPlanner.appNameAliases[query] ?? query

        // 1) Launch Services by display name. This is case-insensitive and, unlike
        //    a plain /Applications scan, also finds system apps that live behind
        //    the read-only/Cryptex firmlinks (e.g. Safari). Try the aliased name
        //    first, then the raw spoken name.
        for candidate in [aliased, query] where !candidate.isEmpty {
            if let path = NSWorkspace.shared.fullPath(forApplication: candidate) {
                return URL(fileURLWithPath: path)
            }
        }

        // 2) Fall back to a scan + fuzzy match for partial names and third-party
        //    apps Launch Services didn't resolve by exact name ("calc",
        //    "activity mon", etc.).
        let index = appIndex()
        if let matched = AppCommandPlanner.resolveAppName(spokenName, installedNames: Array(index.keys)) {
            return index[matched]
        }
        return nil
    }

    /// Builds (and caches) a map of lowercased app display name → bundle URL.
    private static func appIndex() -> [String: URL] {
        if !cachedIndex.isEmpty, Date().timeIntervalSince(cacheBuiltAt) < 300 {
            return cachedIndex
        }
        var index: [String: URL] = [:]
        let fileManager = FileManager.default
        for root in searchRoots {
            for appURL in appBundles(in: root, fileManager: fileManager) {
                let name = appURL.deletingPathExtension().lastPathComponent.lowercased()
                // Don't let a deeper duplicate shadow a top-level app of the same name.
                if index[name] == nil { index[name] = appURL }
            }
        }
        cachedIndex = index
        cacheBuiltAt = Date()
        return index
    }

    /// *.app bundles directly in `root` plus one level of subfolders.
    private static func appBundles(in root: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var bundles: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                bundles.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // One level deep only (e.g. /Applications/Utilities/*.app).
                if let nested = try? fileManager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) {
                    bundles.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }
        return bundles
    }
}
