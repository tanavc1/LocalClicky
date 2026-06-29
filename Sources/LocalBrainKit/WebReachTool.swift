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

    /// A keyless fallback search URL (DuckDuckGo Lite via Jina Reader). Used only
    /// when the primary results page comes back empty or rate-limited, so a single
    /// transient hiccup doesn't turn into "i couldn't reach the web".
    public static func fallbackSearchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "\(jinaReaderBase)https://lite.duckduckgo.com/lite/?q=\(encoded)")
    }

    /// Searches the web (keyless) and returns the results page as markdown. Tries
    /// the primary results page, then a fallback source, so an occasional empty
    /// or rate-limited response still yields an answer.
    public static func search(_ query: String) async -> String? {
        if let url = searchURL(for: query),
           let primary = await fetchMarkdown(url),
           primary.count > 200 {
            return primary
        }
        if let fallbackURL = fallbackSearchURL(for: query) {
            return await fetchMarkdown(fallbackURL)
        }
        return nil
    }

    /// Reads a specific page and returns it as markdown.
    public static func read(_ pageURL: String) async -> String? {
        guard let url = readURL(for: pageURL) else { return nil }
        return await fetchMarkdown(url)
    }

    // MARK: - Weather (a dedicated, accurate, keyless source)

    /// True when the question is about current weather. General web search results
    /// don't carry live weather data, so these go to a dedicated source instead.
    public static func isWeatherQuery(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("weather") || lowered.contains("forecast")
            || lowered.contains("temperature outside") || lowered.contains("how hot is it")
            || lowered.contains("how cold is it")
    }

    /// Extracts a location from "weather in <place>" / "for <place>" / "at <place>",
    /// or nil to use the user's IP-based location.
    public static func weatherLocation(in text: String) -> String? {
        let lowered = text.lowercased()
        for marker in [" in ", " for ", " at "] {
            guard let range = lowered.range(of: marker) else { continue }
            var place = String(lowered[range.upperBound...])
            for suffix in [" right now", " today", " tonight", " tomorrow", " online",
                           " currently", " like", "?", "."] {
                if place.hasSuffix(suffix) { place = String(place.dropLast(suffix.count)) }
            }
            place = place.trimmingCharacters(in: .whitespacesAndNewlines)
            if !place.isEmpty && place.count < 60 { return place }
        }
        return nil
    }

    /// Fetches a concise current-weather report from wttr.in (free, no API key).
    /// `location` nil → the user's IP-based location. Returns a one-line summary
    /// like "San Francisco: Partly cloudy, +61°F (feels like +60°F), humidity 72%".
    public static func weatherReport(forQuery query: String, timeout: TimeInterval = 12) async -> String? {
        let location = weatherLocation(in: query)
        let path = location?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let format = "%l: %C, %t (feels like %f), humidity %h, wind %w"
        let encodedFormat = format.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? format
        guard let url = URL(string: "https://wttr.in/\(path)?format=\(encodedFormat)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("curl/8", forHTTPHeaderField: "User-Agent") // wttr.in returns plain text to curl-like agents
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against wttr.in's "Unknown location" / error pages.
            guard !trimmed.isEmpty, trimmed.count < 300,
                  !trimmed.lowercased().contains("unknown location"),
                  trimmed.contains("°") || trimmed.lowercased().contains("humidity") else { return nil }
            return trimmed
        } catch {
            return nil
        }
    }
}
