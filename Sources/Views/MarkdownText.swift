import SwiftUI

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

    private var attributed: AttributedString {
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
                link.link = URL(string: "daystream://page?name=" + encodeName(name))
                link.foregroundColor = .accentColor
                link.underlineStyle = .single
                if strikethrough {
                    link.strikethroughStyle = .single
                }
                result += link
            }
        }
        return result
    }

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
