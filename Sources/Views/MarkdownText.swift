import SwiftUI

/// A fenced code block in the stream/pages: monospaced, whitespace-preserving,
/// selectable. Language from the info string (```swift) shows as a caption.
struct CodeBlockView: View {
    @Environment(AppSettings.self) private var settings
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(code.isEmpty ? " " : code)
                .font(.system(size: max(10, settings.fontSize - 1), design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .glassCardBackground(in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Renders one line of markdown content: `**bold**`, `*italic*`, `` `code` ``,
/// `[links](url)`, and Logseq `[[wikilinks]]` (intercepted via a custom URL
/// scheme and routed through the environment's openURL action).
struct MarkdownText: View {
    let content: String
    var strikethrough: Bool = false
    var color: Color = .primary

    var body: some View {
        Text(attributed)
            .foregroundStyle(color)
    }

    /// Parsing markdown per body evaluation made scrolling janky — every
    /// visible row re-parsed on every frame of the stream's lazy stack.
    /// AttributedString is a value type, so the cache stores a box.
    private static let cache: NSCache<NSString, AttributedBox> = {
        let c = NSCache<NSString, AttributedBox>()
        c.totalCostLimit = 8192
        return c
    }()

    private final class AttributedBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private var attributed: AttributedString {
        let key = "\(strikethrough ? "s" : "p")‖\(content)" as NSString
        if let boxed = Self.cache.object(forKey: key) { return boxed.value }
        let value = buildAttributed()
        Self.cache.setObject(AttributedBox(value), forKey: key, cost: 1)
        return value
    }

    private func buildAttributed() -> AttributedString {
        var result = AttributedString()
        let parts = splitWikilinks(content)
        for part in parts {
            switch part {
            case .text(let raw):
                var chunk = parseMarkdown(raw)
                if strikethrough, !raw.isEmpty {
                    chunk.strikethroughStyle = .single
                }
                result += chunk
            case .wiki(let name):
                var link = AttributedString(name)
                // Date-like wikilinks ([[Aug 18th, 2026]], [[2026-08-18]]) jump
                // to that day in the stream; everything else opens the page.
                if let day = WikiDate.parse(name) {
                    link.link = URL(string: "daystream://date?value=" + Self.isoDayFormatter.string(from: day))
                } else {
                    link.link = URL(string: "daystream://page?name=" + encodeName(name))
                }
                link.foregroundColor = Color.readableLink
                link.underlineStyle = .single
                if strikethrough {
                    link.strikethroughStyle = .single
                }
                result += link
            }
        }
        return result
    }

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func encodeName(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
    }

    private func parseMarkdown(_ raw: String) -> AttributedString {
        guard !raw.isEmpty else { return AttributedString() }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attr = (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
        if strikethrough {
            attr.strikethroughStyle = .single
        }
        return attr
    }
}

private enum MarkdownPart {
    case text(String)
    case wiki(String)
}

private func splitWikilinks(_ s: String) -> [MarkdownPart] {
    var parts: [MarkdownPart] = []
    var current = s.startIndex
    let chars = Array(s)
    var i = 0

    // Manual scan for [[...]] (AttributedString markdown chokes on brackets otherwise).
    while i < chars.count - 1 {
        if chars[i] == "[", chars[i + 1] == "[" {
            // find closing ]]
            if let close = findClosing(chars, from: i + 2) {
                let before = String(s[current..<s.index(s.startIndex, offsetBy: i)])
                if !before.isEmpty { parts.append(.text(before)) }
                let name = String(chars[(i + 2)..<close])
                parts.append(.wiki(name))
                i = close + 2
                current = s.index(s.startIndex, offsetBy: i)
                continue
            }
        }
        i += 1
    }
    let tail = String(s[current...])
    if !tail.isEmpty { parts.append(.text(tail)) }
    return parts
}

private func findClosing(_ chars: [Character], from: Int) -> Int? {
    var j = from
    while j < chars.count - 1 {
        if chars[j] == "]", chars[j + 1] == "]" {
            return j
        }
        j += 1
    }
    return nil
}
