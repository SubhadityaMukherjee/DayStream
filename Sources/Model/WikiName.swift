import Foundation

/// Logseq page-name <-> filename conversion.
/// Logseq (`:file/name-format :triple-lowbar`) maps `/` in page names to `___`
/// and percent-encodes other filename-hostile characters.
enum WikiName {
    private static let invalidCharacters = ":%\\?*<>|\"#[]^"

    static func fileName(for pageName: String) -> String {
        var out = ""
        for ch in pageName {
            switch ch {
            case "/":
                out += "___"
            case "%":
                out += "%25"
            default:
                let isInvalid = String(ch).rangeOfCharacter(
                    from: CharacterSet(charactersIn: invalidCharacters)) != nil
                let isOddWhitespace = ch != " " && ch.isWhitespace
                if isInvalid || isOddWhitespace {
                    let encoded = String(ch).data(using: .utf8)!
                        .map { String(format: "%%%02X", $0) }
                        .joined()
                    out += encoded
                } else {
                    out.append(ch)
                }
            }
        }
        return out + ".md"
    }

    static func pageName(for fileName: String) -> String {
        let name = (fileName as NSString).deletingPathExtension
        return name
            .replacingOccurrences(of: "___", with: "/")
            .removingPercentEncoding ?? name
    }

    /// File names that may hold the given page, most likely first.
    static func candidateFileNames(for pageName: String) -> [String] {
        [fileName(for: pageName), pageName + ".md"]
    }

    // MARK: - Wikilink routing

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The `daystream://` URL a clicked wikilink routes to: date-like names
    /// (`[[Aug 18th, 2026]]`, `[[2026-08-18]]`) jump to that day in the
    /// stream, everything else opens the page. MainView's openURL action
    /// is the single consumer, so rendered views and the editor can't drift.
    static func linkURL(forWikilink name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let day = WikiDate.parse(trimmed) {
            return URL(string: "daystream://date?value=" + isoDayFormatter.string(from: day))
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "daystream://page?name=" + encoded)
    }

    // MARK: - Wikilink scanning

    private static let wikilinkRegex = try? NSRegularExpression(pattern: "\\[\\[([^\\[\\]]+)\\]\\]")

    /// All `[[target]]` names appearing in the given text.
    static func wikilinkTargets(in text: String) -> [String] {
        guard let regex = wikilinkRegex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
            }
    }

    /// True when the text contains `[[name]]` (case-insensitive, whitespace-trimmed).
    static func references(_ text: String, page name: String) -> Bool {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return false }
        return wikilinkTargets(in: text).contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == target
        }
    }
}
