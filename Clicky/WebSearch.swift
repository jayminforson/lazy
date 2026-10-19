//
//  WebSearch.swift
//  Clicky
//
//  Keyless web search (M4 freshness): DuckDuckGo's no-JS HTML endpoint,
//  called only when the Gemini brain answers a [SEARCH: ...] marker.
//  No API key, no account, no quota — strict $0 (a keyed search API would
//  break the app's "exactly two credentials" rule, and Gemini's native
//  Google Search grounding is not available on the free tier for Gemini 3
//  models). Fail-soft by design: any problem returns nil and the brain
//  answers honestly that it could not check online.
//

import Foundation

struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

enum WebSearch {

    /// Runs a web search. Returns the top results, or nil when the endpoint
    /// fails, times out, or yields nothing usable.
    static func search(_ query: String) async -> [WebSearchResult]? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        guard let endpointURL = URL(string: "https://html.duckduckgo.com/html/") else { return nil }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let formBody = "q=\(urlEncoded(trimmedQuery))&kl=us-en"
        request.httpBody = Data(formBody.utf8)

        let pageHTML: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("🌐 WebSearch: non-200 for \"\(trimmedQuery)\"")
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return nil
            }
            pageHTML = html
        } catch {
            print("🌐 WebSearch: request failed for \"\(trimmedQuery)\" — \(error.localizedDescription)")
            return nil
        }

        let results = parseResults(from: pageHTML)
        if results.isEmpty {
            print("🌐 WebSearch: no results parsed for \"\(trimmedQuery)\"")
            return nil
        }
        print("🌐 WebSearch: \(results.count) results for \"\(trimmedQuery)\"")
        return results
    }

    // MARK: - Parsing

    private static func parseResults(from html: String) -> [WebSearchResult] {
        // Title links: <a ... class="result__a" href="...">Title</a>
        let linkTags = matches(pattern: #"<a[^>]*class="result__a"[^>]*>.*?</a>"#, in: html)
        guard !linkTags.isEmpty else { return [] }

        // Snippets ride along in order: <a class="result__snippet" ...>...</a>
        let snippetTags = matches(pattern: #"<a[^>]*class="result__snippet"[^>]*>.*?</a>"#, in: html)

        var results: [WebSearchResult] = []
        for (index, linkTag) in linkTags.enumerated() {
            guard let href = attributeValue("href", in: linkTag) else { continue }
            let title = innerText(of: linkTag)
            let snippet = index < snippetTags.count ? innerText(of: snippetTags[index]) : ""
            guard !title.isEmpty, let url = normalizedURL(from: href) else { continue }
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            if results.count >= 6 { break }
        }
        return results
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\#(name)="([^"]+)""#) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[valueRange])
    }

    /// Strips tags, decodes HTML entities → plain text.
    private static func innerText(of tag: String) -> String {
        guard let openAngle = tag.firstIndex(of: ">"), openAngle < tag.index(before: tag.endIndex) else { return "" }
        let afterOpen = tag.index(after: openAngle)
        guard let closeAngle = tag[afterOpen...].lastIndex(of: ">") else { return "" }
        let rawInner = String(tag[afterOpen..<closeAngle])
        let stripped = rawInner.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var decoded = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"),
            ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }

    /// DDG sometimes wraps destinations as //duckduckgo.com/l/?uddg=<pct-encoded>;
    /// direct URLs pass through. Returns nil for junk.
    private static func normalizedURL(from href: String) -> String? {
        var cleaned = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
        if let uddgRange = cleaned.range(of: "uddg=") {
            let encoded = cleaned[uddgRange.upperBound...]
            let untilDelimiter = encoded.prefix { $0 != "&" && $0 != "#" }
            if let decoded = String(untilDelimiter).removingPercentEncoding, decoded.hasPrefix("http") {
                cleaned = decoded
            }
        }
        guard cleaned.hasPrefix("http"), let url = URL(string: cleaned) else { return nil }
        return url.absoluteString
    }

    private static func urlEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
