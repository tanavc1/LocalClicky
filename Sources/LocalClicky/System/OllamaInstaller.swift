//
//  OllamaInstaller.swift
//  LocalClicky
//
//  Detects whether Ollama is installed/running and offers a one-click install.
//  Inference itself is always localhost-only; the only network here is the
//  one-time, user-initiated download of the official Ollama app from ollama.com
//  (documented setup traffic, not telemetry).
//

import AppKit
import Foundation

enum OllamaInstaller {
    /// Official Ollama macOS download (a notarized .zip) + the human download page
    /// used as a fallback. Both are user-initiated, setup-only.
    static let downloadZipURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    static let downloadPageURL = URL(string: "https://ollama.com/download")!

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Where the Ollama app may live.
    private static var appPaths: [String] {
        ["/Applications/Ollama.app", "\(home)/Applications/Ollama.app"]
    }

    /// Where the `ollama` CLI may live.
    private static var binaryPaths: [String] {
        ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama",
         "/Applications/Ollama.app/Contents/Resources/ollama"]
    }

    /// True if Ollama appears installed (app bundle or CLI present). This is
    /// distinct from "running" — the server may still need launching.
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        if appPaths.contains(where: { fm.fileExists(atPath: $0) }) { return true }
        if binaryPaths.contains(where: { fm.isExecutableFile(atPath: $0) }) { return true }
        return false
    }

    /// Launches the installed Ollama app (which starts its local server). Returns
    /// false if no app bundle is present to launch.
    @discardableResult
    static func launchInstalledApp() -> Bool {
        let fm = FileManager.default
        guard let path = appPaths.first(where: { fm.fileExists(atPath: $0) }) else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
    }

    /// Result of an install attempt, surfaced to the panel.
    enum InstallOutcome: Equatable {
        case installedAndLaunched
        case openedDownloadPage   // fallback: user finishes the standard drag-install
        case failed(String)
    }

    /// One-click install: downloads the official Ollama app, unzips it, moves it
    /// into Applications, and launches it. Every step has a safe fallback — on any
    /// failure it opens the official download page so the user can finish the
    /// standard drag-to-Applications install. Network is the single user-initiated
    /// fetch from ollama.com.
    static func install() async -> InstallOutcome {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("LocalClicky-ollama-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            // 1) Download the official zip.
            let (downloaded, response) = try await URLSession.shared.download(from: downloadZipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return await openPageFallback()
            }
            let zipPath = tmp.appendingPathComponent("Ollama.zip")
            try? fm.removeItem(at: zipPath)
            try fm.moveItem(at: downloaded, to: zipPath)

            // 2) Unzip with the system unarchiver.
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipPath.path, tmp.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  let appInZip = try? fm.contentsOfDirectory(atPath: tmp.path)
                    .first(where: { $0.hasSuffix(".app") }) else {
                return await openPageFallback()
            }
            let sourceApp = tmp.appendingPathComponent(appInZip)

            // 3) Move into Applications (fall back to ~/Applications if /Applications
            //    isn't writable), replacing any partial copy.
            let destinations = ["/Applications/Ollama.app", "\(home)/Applications/Ollama.app"]
            var installedPath: String?
            for dest in destinations {
                let parent = (dest as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try? fm.removeItem(atPath: dest)
                do {
                    try fm.copyItem(atPath: sourceApp.path, toPath: dest)
                    installedPath = dest
                    break
                } catch { continue }
            }
            guard let installed = installedPath else { return await openPageFallback() }

            // 4) Clear quarantine (best-effort; the app is notarized anyway) + launch.
            let dequarantine = Process()
            dequarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            dequarantine.arguments = ["-dr", "com.apple.quarantine", installed]
            try? dequarantine.run()
            dequarantine.waitUntilExit()

            NSWorkspace.shared.open(URL(fileURLWithPath: installed))
            return .installedAndLaunched
        } catch {
            return await openPageFallback()
        }
    }

    @MainActor
    private static func openPageFallback() -> InstallOutcome {
        NSWorkspace.shared.open(downloadPageURL)
        return .openedDownloadPage
    }
}
