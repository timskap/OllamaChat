import Foundation

struct WebSearchResult {
    let title: String
    let snippet: String
    let url: String
}

class WebSearchService {
    static let shared = WebSearchService()

    /// Search DuckDuckGo Lite and return top results
    func search(query: String, maxResults: Int = 5) async -> [WebSearchResult] {
        guard let url = URL(string: "https://lite.duckduckgo.com/lite/") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        request.httpBody = body.data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return [] }

        return parseLiteResults(html: html, max: maxResults)
    }

    /// Format search results as context text for the LLM
    func searchAndFormat(query: String, maxResults: Int = 5) async -> String? {
        let results = await search(query: query, maxResults: maxResults)
        if results.isEmpty { return nil }

        var text = "Web search results for: \"\(query)\"\n\n"
        for (i, r) in results.enumerated() {
            text += "[\(i + 1)] \(r.title)\n\(r.snippet)\nURL: \(r.url)\n\n"
        }
        text += "Use the above search results to inform your response. Cite sources when relevant."
        return text
    }

    // MARK: - DuckDuckGo Lite Parser

    private func parseLiteResults(html: String, max: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        // Extract links: href comes before class='result-link'
        let links = extractAll(from: html, pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*class='result-link'>([^<]+)</a>")
        // Extract snippets with class="result-snippet"
        let snippets = extractAllContent(from: html, tag: "result-snippet")

        for i in 0..<min(links.count, max) {
            let (url, title) = links[i]
            let snippet = i < snippets.count ? snippets[i] : ""

            // Skip ads/empty
            if url.isEmpty || title.isEmpty { continue }

            results.append(WebSearchResult(
                title: decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
                snippet: decodeEntities(stripTags(snippet)).trimmingCharacters(in: .whitespacesAndNewlines),
                url: url
            ))
        }
        return results
    }

    /// Extract all matches of (href, text) from result-link anchors
    private func extractAll(from html: String, pattern: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            return (String(html[urlRange]), String(html[titleRange]))
        }
    }

    /// Extract text content from all elements with a given class
    private func extractAllContent(from html: String, tag: String) -> [String] {
        let pattern = "class='\(tag)'[^>]*>([\\s\\S]*?)</td>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let contentRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[contentRange])
        }
    }

    private func stripTags(_ html: String) -> String {
        var result = html
        while let start = result.range(of: "<"), let end = result.range(of: ">", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound...end.lowerBound)
        }
        return result
    }

    private func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
