//
//  WebReachTool.swift
//  LocalBrainKit
//
//  The ONE deliberate exception to LocalClicky's no-cloud rule: an opt-in web
//  tool for questions that genuinely need the internet (current events, "look it
//  up online", "what's the latest…"). It implements the proven core of the
//  agent-reach project natively — web reading + search through Jina Reader
//  (https://r.jina.ai), which returns any page (or a DuckDuckGo results page) as
//  clean markdown with no API key, no cookies, and no system install. See
//  docs/agent-reach-spike.md for why we ship this instead of bundling the full
//  agent-reach toolchain.
//
//  IMPORTANT: this is the only place in LocalBrainKit that contacts a non-local
//  host, and it runs only on the explicit `.webReach` route. All inference and
//  every other feature remain fully local.
//

import Foundation

public enum WebReachTool {
    /// Jina Reader — turns any URL into clean markdown. The single cloud endpoint
    /// this tool uses. Documented + opt-in.
    public static let jinaReaderBase = "https://r.jina.ai/"
    public static var endpointHost: String { "r.jina.ai" }

    /// Builds the read URL for a page: `https://r.jina.ai/<original-url>`.
    public static func readURL(for pageURL: String) -> URL? {
        let normalized = pageURL.hasPrefix("http") ? pageURL : "https://\(pageURL)"
        return URL(string: jinaReaderBase + normalized)
    }

    /// Builds a keyless search URL: Jina Reader over a DuckDuckGo HTML results
    /// page. Returns ranked results (titles, snippets, links) as markdown.
    public static func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "\(jinaReaderBase)https://duckduckgo.com/html/?q=\(encoded)")
    }

    /// Fetches markdown from a Jina Reader URL, truncated to `maxCharacters` so a
    /// huge page can't blow the model's context. Returns nil on any failure.
    public static func fetchMarkdown(_ url: URL, timeout: TimeInterval = 25, maxCharacters: Int = 6000) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Ask Jina to drop images so the markdown is lean + model-friendly.
        request.setValue("none", forHTTPHeaderField: "X-Retain-Images")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            return text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
        } catch {
            return nil
        }
    }

    /// Searches the web (keyless) and returns the results page as markdown.
    public static func search(_ query: String) async -> String? {
        guard let url = searchURL(for: query) else { return nil }
        return await fetchMarkdown(url)
    }

    /// Reads a specific page and returns it as markdown.
    public static func read(_ pageURL: String) async -> String? {
        guard let url = readURL(for: pageURL) else { return nil }
        return await fetchMarkdown(url)
    }
}
