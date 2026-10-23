//
//  WebSearch.swift
//  Clicky
//
//  Keyless web search (M4 freshness, hardened in M4.5d after the
//  2026-10-20 freeze): TWO no-JS HTML engines tried in order —
//  DuckDuckGo, then Bing — under one hard wall-clock deadline and a
//  circuit breaker. No API key, no account, no quota — strict $0 (a keyed
//  search API would break the app's "exactly two credentials" rule, and
//  Gemini's native Google Search grounding is not available on the free
//  tier for Gemini 3 models). Fail-soft by design: any problem returns nil
//  and the brain answers honestly that it could not check online.
//
//  Engine probe results, this machine, 2026-10-20 (CONTENT verified, not
//  just status codes — the Mojeek "200" was a 5.5 KB captcha page):
//    DuckDuckGo html → HTTP 202 anomaly page on EVERY request (POST and
//      GET, html and lite endpoints) — the silent no-op that starved every
//      freshness question in the freeze drill. Kept FIRST: cleanest parse
//      when it un-rate-limits.
//    Bing → HTTP 200, real organic results: <li class="b_algo"> blocks,
//      titles in <h2><a href="…">, destinations base64url-wrapped in the
//      ck/a redirect's u=a1… parameter, snippets in <p class="b_lineclamp…">.
//    Mojeek → 200 but a CAPTCHA page. Ecosia → 403 firewall. searx.be →
//      browser-verification wall. Startpage/Google → empty shells.
//  The breaker (3 consecutive total failures → skip 5 min) turns a dead
//  search into one probe per window instead of paying its latency — and
//  its marker-round amplification — on every turn.
//

import Foundation

struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

enum WebSearch {

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    /// One hard wall-clock budget for the WHOLE search (both engines). A
    /// request's timeoutInterval only bounds idle-between-packets and
    /// URLSession.shared's resource timeout is 7 days — neither can stop a
    /// trickling or wedged response. The search races a clock and the
    /// loser's task is cancelled, so a current-info ask can never again sit
    /// in search for tens of seconds before a single word streams.
    private static let totalDeadlineSeconds: Double = 6

    /// Per-request idle budget — below the total so a slow engine hands the
    /// turn to the next one instead of eating the whole deadline.
    private static let requestTimeoutSeconds: TimeInterval = 4

    /// Circuit breaker: after this many consecutive TOTAL failures (across
    /// both engines), skip searching entirely for the skip window.
    private static let failuresBeforeSkip = 3
    private static let skipWindowSeconds: Double = 300
    private static var consecutiveTotalFailures = 0
    private static var skipSearchUntilUptime: TimeInterval = 0

    /// One search attempt, as seen by the deadline race.
    private enum Attempt {
        case results([WebSearchResult])
        case failed
        case deadline
    }

    /// Runs a web search. Returns the top results, or nil when both engines
    /// fail, the deadline fires, or the circuit is open.
    static func search(_ query: String) async -> [WebSearchResult]? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        let shortQuery = String(trimmedQuery.prefix(60))

        if ProcessInfo.processInfo.systemUptime < skipSearchUntilUptime {
            print("🌐 WebSearch: circuit open — skipping \"\(shortQuery)\"")
            BrainLog.line("websearch: circuit open — skipped \"\(shortQuery)\"")
            return nil
        }

        let attempt = await withTaskGroup(of: Attempt.self) { group -> Attempt in
            group.addTask {
                if let results = await runEngines(query: trimmedQuery) {
                    return .results(results)
                }
                return .failed
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(totalDeadlineSeconds * 1_000_000_000))
                return .deadline
            }
            for await value in group {
                // First outcome decides; the remaining child (the sleeper,
                // or the engines mid-flight after a deadline) is cancelled
                // — URLSession honors task cancellation immediately.
                group.cancelAll()
                return value
            }
            return .failed
        }

        switch attempt {
        case .results(let results):
            noteTotalOutcome(success: true)
            print("🌐 WebSearch: \(results.count) results for \"\(shortQuery)\"")
            return results
        case .failed:
            noteTotalOutcome(success: false)
            print("🌐 WebSearch: both engines failed for \"\(shortQuery)\"")
            BrainLog.line("websearch: both engines failed — \"\(shortQuery)\"")
            return nil
        case .deadline:
            noteTotalOutcome(success: false)
            print("🌐 WebSearch: hard \(Int(totalDeadlineSeconds))s deadline — gave up on \"\(shortQuery)\"")
            BrainLog.line("websearch: \(Int(totalDeadlineSeconds))s deadline hit — \"\(shortQuery)\"")
            return nil
        }
    }

    /// Both engines at once (M11). Racing replaces the old sequential
    /// DDG-then-Bing order because DuckDuckGo has been rate-limiting this
    /// machine often enough (2026-10-23: "no parseable results" on every
    /// probe) that waiting out its ~3–5 s failure before starting Bing
    /// burned most of the 6 s budget — searches hit the hard deadline or
    /// limped back at ~5 s. First non-empty result wins; the loser is
    /// cancelled (URLSession honors task cancellation immediately).
    private static func runEngines(query: String) async -> [WebSearchResult]? {
        await withTaskGroup(of: [WebSearchResult].self) { group -> [WebSearchResult]? in
            group.addTask { await fetchDuckDuckGo(query) ?? [] }
            group.addTask { await fetchBing(query) ?? [] }
            for await results in group {
                if !results.isEmpty {
                    group.cancelAll()
                    return results
                }
            }
            return nil
        }
    }

    /// Circuit-breaker bookkeeping — a success re-opens the circuit at once.
    private static func noteTotalOutcome(success: Bool) {
        if success {
            consecutiveTotalFailures = 0
            skipSearchUntilUptime = 0
            return
        }
        consecutiveTotalFailures += 1
        if consecutiveTotalFailures >= failuresBeforeSkip {
            skipSearchUntilUptime = ProcessInfo.processInfo.systemUptime + skipWindowSeconds
            print("🌐 WebSearch: \(consecutiveTotalFailures) consecutive failures — circuit OPEN for \(Int(skipWindowSeconds / 60)) min")
            BrainLog.line("websearch: circuit OPEN — \(consecutiveTotalFailures) consecutive failures, skipping \(Int(skipWindowSeconds / 60)) min")
        }
    }

    // MARK: - Engine 1: DuckDuckGo (POST, no-JS HTML)

    private static func fetchDuckDuckGo(_ query: String) async -> [WebSearchResult]? {
        guard let endpointURL = URL(string: "https://html.duckduckgo.com/html/") else { return nil }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "q=\(urlEncoded(query))&b=&kl=us-en".data(using: .utf8)

        let pageHTML: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            // 202 = DDG's anomaly/rate-limit page, NOT results (the
            // 2026-10-20 freeze: every request answered 202).
            guard http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                BrainLog.line("websearch: duckduckgo http=\(http.statusCode) (non-200 → bing next)")
                return nil
            }
            pageHTML = html
        } catch {
            if !Task.isCancelled {
                print("🌐 WebSearch: duckduckgo request failed — \(error.localizedDescription)")
                BrainLog.line("websearch: duckduckgo request failed — \(error.localizedDescription)")
            }
            return nil
        }

        let results = parseDuckDuckGoResults(from: pageHTML)
        if results.isEmpty {
            BrainLog.line("websearch: duckduckgo returned no parseable results")
            return nil
        }
        print("🌐 WebSearch(duckduckgo): \(results.count) results")
        return results
    }

    // MARK: - Engine 2: Bing (GET, no-JS HTML)

    private static func fetchBing(_ query: String) async -> [WebSearchResult]? {
        guard let endpointURL = URL(string: "https://www.bing.com/search?q=\(urlEncoded(query))&count=10&setlang=en") else { return nil }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let pageHTML: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                BrainLog.line("websearch: bing http=\(http.statusCode)")
                return nil
            }
            pageHTML = html
        } catch {
            if !Task.isCancelled {
                print("🌐 WebSearch: bing request failed — \(error.localizedDescription)")
                BrainLog.line("websearch: bing request failed — \(error.localizedDescription)")
            }
            return nil
        }

        let results = parseBingResults(from: pageHTML)
        if results.isEmpty {
            BrainLog.line("websearch: bing returned no parseable results")
            return nil
        }
        print("🌐 WebSearch(bing): \(results.count) results")
        return results
    }

    // MARK: - Parsing (DuckDuckGo)

    private static func parseDuckDuckGoResults(from html: String) -> [WebSearchResult] {
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

    // MARK: - Parsing (Bing)

    /// Parses Bing's organic blocks. Internal (not private) so the parser
    /// harness can compile it against a saved real page — the parser was
    /// written from live markup and markup drifts.
    static func parseBingResults(from html: String) -> [WebSearchResult] {
        // Blocks: <li class="b_algo" …> … up to the next one. Each carries
        // <h2><a href="…/ck/a?…&u=a1<base64url>">Title</a></h2> and usually
        // a snippet <p class="b_lineclamp…">…</p> (b_lineclamp2/3/4/…).
        let blocks = html.components(separatedBy: "<li class=\"b_algo")
        var results: [WebSearchResult] = []
        for block in blocks.dropFirst() {  // [0] is everything before the first result
            guard let href = firstCapture(pattern: #"<h2><a[^>]*href="([^"]+)""#, in: block),
                  let titleInner = firstCapture(pattern: #"<h2><a[^>]*>(.*?)</a>"#, in: block)
            else { continue }
            // innerText strips nested markup (<b> highlights) + decodes entities.
            let title = innerText(of: "<t>\(titleInner)</t>")
            guard !title.isEmpty, let url = bingDestinationURL(fromRedirectHref: href) else { continue }
            let snippetInner = firstCapture(pattern: #"<p[^>]*class="b_lineclamp[^"]*"[^>]*>(.*?)</p>"#, in: block) ?? ""
            let snippet = innerText(of: "<t>\(snippetInner)</t>")
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            if results.count >= 6 { break }
        }
        return results
    }

    /// Bing wraps destinations as /ck/a?…&u=a1<base64url of the real URL>
    /// (HTML-escaped &amp; in the raw href). Direct http(s) hrefs pass
    /// through. Returns nil when nothing usable decodes — a raw ck/a link
    /// in an answer would just be a tracking redirect.
    static func bingDestinationURL(fromRedirectHref href: String) -> String? {
        let cleaned = decodeEntities(href)
        if let encoded = firstCapture(pattern: #"[?&]u=a1([A-Za-z0-9_-]+)"#, in: cleaned) {
            var padded = encoded
            while padded.count % 4 != 0 { padded += "=" }
            let normalized = padded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            if let data = Data(base64Encoded: normalized),
               let decoded = String(data: data, encoding: .utf8),
               decoded.hasPrefix("http"),
               let url = URL(string: decoded) {
                return url.absoluteString
            }
        }
        if cleaned.hasPrefix("http"), let url = URL(string: cleaned) {
            return url.absoluteString
        }
        return nil
    }

    // MARK: - Shared parsing helpers

    /// First regex match's capture group 1 (nil when absent).
    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
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
        // Cut at the closing tag's "<" — cutting at the last ">" (the old
        // way) left a trailing "</a"-style artifact in every title and
        // snippet; lastIndex(of: "<") still handles nested <b> highlight
        // tags (it finds the OUTERMOST closing tag). Caught by the M4.5d
        // parser harness; the artifact had silently ridden along in DDG
        // results since M4.5 (the model tolerated it; nothing displayed it).
        let closingStart = tag[afterOpen...].lastIndex(of: "<") ?? tag.endIndex
        let rawInner = String(tag[afterOpen..<closingStart])
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
