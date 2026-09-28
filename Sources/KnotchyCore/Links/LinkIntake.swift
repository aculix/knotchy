import Foundation

/// Input is untrusted and scanned inside the synchronous Services call, so work is linear and capped.
public enum LinkIntake {
    /// UTF-8 bytes. Links reach the VM in an env var and in NAVIGATE messages (64 KiB limit).
    public static let maxURLBytes = 16 * 1024
    public static let maxScannedCharacters = 1024 * 1024

    /// The first http(s) URL in `text`, without surrounding prose punctuation, quotes or Markdown.
    public static func extractURL(from text: String) -> URL? {
        let startLimit = text.index(text.startIndex, offsetBy: maxScannedCharacters, limitedBy: text.endIndex)
            ?? text.endIndex
        // One past the limit, so an over-long link is rejected rather than truncated.
        let readLimit = text.index(startLimit, offsetBy: maxURLBytes + 1, limitedBy: text.endIndex) ?? text.endIndex
        var from = text.startIndex
        while from < startLimit,
              let match = text.range(of: "http", options: .caseInsensitive, range: from..<startLimit) {
            let end = text[match.lowerBound..<readLimit].firstIndex(where: endsURL) ?? readLimit
            let token = text[match.lowerBound..<end]
            let before = match.lowerBound > text.startIndex ? text[text.index(before: match.lowerBound)] : nil
            var parts = [(token, afterParenthesis: before == "(")]
            if let markdown = token.range(of: "](") {
                parts = [(token[..<markdown.lowerBound], before == "("), (token[markdown.upperBound...], true)]
            }
            for (whole, afterParenthesis) in parts {
                let part = afterParenthesis ? upToUnbalancedClosingParenthesis(whole) : whole
                let candidate = trimmingTrailingPunctuation(part, stripping: before == "*" ? ".,;:!?\"'*" : ".,;:!?\"'")
                if candidate.utf8.count <= maxURLBytes,
                   let url = URL(string: String(candidate)),
                   let valid = validate(url) {
                    return valid
                }
            }
            from = end
        }
        return nil
    }

    /// Tries `href` targets first: a selected hyperlink's visible text rarely contains its address.
    public static func extractURL(fromHTML html: String) -> URL? {
        let text = String(html.prefix(maxScannedCharacters))
        let range = NSRange(text.startIndex..., in: text)
        for match in hrefPattern.matches(in: text, range: range) {
            for group in 1...3 {
                guard let found = Range(match.range(at: group), in: text) else { continue }
                let target = decodingEntities(text[found]).trimmingCharacters(in: .whitespacesAndNewlines)
                if target.utf8.count <= maxURLBytes, let url = URL(string: target), let valid = validate(url) {
                    return valid
                }
            }
        }
        return extractURL(from: text)
    }

    private static let hrefPattern = try! NSRegularExpression(
        pattern: #"href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, options: [.caseInsensitive])

    private static func decodingEntities(_ value: Substring) -> String {
        var result = String(value)
        for (entity, character) in [("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&#38;", "&"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return result
    }

    public static func validate(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty,
              url.absoluteString.utf8.count <= maxURLBytes
        else { return nil }
        return url
    }

    /// Missed by the category check. IDNA would turn these full stops into dots in the host.
    private static let cjkPunctuation: Set<Character> = ["。", "．", "｡", "、", "，", "…", "！", "？", "：", "；"]

    private static func endsURL(_ c: Character) -> Bool {
        if c.isWhitespace || c == "<" || c == ">" || c == "\"" || c == "`" { return true }
        guard let scalar = c.unicodeScalars.first, !scalar.isASCII else { return false }
        switch scalar.properties.generalCategory {
        case .initialPunctuation, .finalPunctuation, .openPunctuation, .closePunctuation:
            return true
        default:
            return cjkPunctuation.contains(c)
        }
    }

    private static func upToUnbalancedClosingParenthesis(_ part: Substring) -> Substring {
        var depth = 0
        for i in part.indices {
            switch part[i] {
            case "(":
                depth += 1
            case ")":
                if depth == 0 { return part[..<i] }
                depth -= 1
            default:
                break
            }
        }
        return part
    }

    private static let openerOf: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    private static let closerOf: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    private static func trimmingTrailingPunctuation(_ token: Substring, stripping punctuation: String) -> Substring {
        // Closing minus opening brackets, keyed by the closing one.
        var unbalanced: [Character: Int] = [:]
        for c in token {
            if openerOf[c] != nil {
                unbalanced[c, default: 0] += 1
            } else if let closer = closerOf[c] {
                unbalanced[closer, default: 0] -= 1
            }
        }
        var s = token
        while let last = s.last {
            if punctuation.contains(last) {
                s.removeLast()
            } else if openerOf[last] != nil, unbalanced[last, default: 0] > 0 {
                unbalanced[last, default: 0] -= 1
                s.removeLast()
            } else {
                break
            }
        }
        return s
    }
}
