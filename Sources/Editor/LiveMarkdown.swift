import Foundation

/// Live-preview logic for the editor: which markdown syntax characters on a
/// line can be hidden once the caret leaves it. Pure text math — the editor's
/// layout-manager delegate turns these ranges into null (zero-width, undrawn)
/// glyphs while the text storage keeps the raw markdown, so saves, undo,
/// autocomplete and the outliner all operate on plain source.
enum LiveMarkdown {
    static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[[^\[\]\n]+\]\]"#)
    static let codeSpanRegex = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    static let boldRegex = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
    static let italicRegex = try! NSRegularExpression(pattern: #"\*[^*\n]+\*"#)
    /// Lookbehind keeps image embeds (`![alt](url)`) fully visible — hiding
    /// them would leave nothing on the line at all.
    static let linkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[[^\[\]\n]+\]\([^()\n]*\)"#)
    /// Headings need whitespace after the hashes (CommonMark-style) so
    /// `#hashtags` keep their marker and plain styling.
    static let headingRegex = try! NSRegularExpression(pattern: #"^\s*#{1,6}(\s\s*|$)"#)

    /// True for real headings (`# Title`, `##Title` is not one) — shared by
    /// hiding and styling so the two can't disagree.
    static func isHeadingLine(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return headingRegex.firstMatch(in: line, range: full) != nil
    }
    /// Internal bookkeeping properties (timestamps, Logseq ids) — hidden
    /// entirely on non-active lines, mirroring what the rendered view hid.
    static let bookkeepingPropertyRegex = try! NSRegularExpression(pattern: #"^\s*(added|completed|id)::"#)

    static func isBookkeepingPropertyLine(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return bookkeepingPropertyRegex.firstMatch(in: line, range: full) != nil
    }

    /// The TODO-family marker word on a bullet line (nil if none) — clicking
    /// it in the editor toggles the task, like the old rendered checkboxes.
    static let todoMarkerRegex = try! NSRegularExpression(
        pattern: #"^\s*[-*]\s(TODO|DOING|LATER|NOW|DONE)(?:\s|$)"#)

    static func todoMarkerRange(inLine line: String) -> NSRange? {
        let full = NSRange(location: 0, length: (line as NSString).length)
        guard let match = todoMarkerRegex.firstMatch(in: line, range: full) else { return nil }
        return match.range(at: 1)
    }

    static let bulletPrefixRegex = try! NSRegularExpression(pattern: #"^\s*[-*][ \t]+"#)

    /// The leading bullet syntax that renders away once the caret leaves the
    /// line: for task lines the bullet + marker + one space (a checkbox is
    /// drawn in its place), for plain bullets the bullet + whitespace. The
    /// indent itself stays visible — nesting must keep reading as structure.
    /// Never includes the line terminator.
    static func renderableBulletPrefix(inLine line: String) -> NSRange? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let marker = todoMarkerRange(inLine: line) {
            var end = NSMaxRange(marker)
            if end < ns.length { end += 1 } // the one space after the marker
            let indent = bulletIndentLength(line)
            return NSRange(location: indent, length: end - indent)
        }
        guard let match = bulletPrefixRegex.firstMatch(in: line, range: full) else { return nil }
        let indent = bulletIndentLength(line)
        return NSRange(location: indent, length: match.range.length - indent)
    }

    /// UTF-16 length of the leading tab/space run (indent is tabs/spaces
    /// only, so this is just the scalar count).
    private static func bulletIndentLength(_ line: String) -> Int {
        line.prefix { $0 == "\t" || $0 == " " }.count
    }

    /// Syntax ranges to hide for one line (patterns are line-local), as
    /// absolute UTF-16 ranges — `offset` is the line's document location.
    /// The caller skips fenced lines and the line holding the caret.
    static func hiddenRanges(line: String, offset: Int) -> [NSRange] {
        let ns = line as NSString
        guard ns.length > 0 else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        var boldMatches: [NSRange] = []

        func delimiters(_ match: NSRange, leading: Int, trailing: Int) {
            guard match.length >= leading + trailing else { return }
            ranges.append(NSRange(location: offset + match.location, length: leading))
            ranges.append(NSRange(location: offset + NSMaxRange(match) - trailing, length: trailing))
        }

        boldRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            boldMatches.append(match.range)
            delimiters(match.range, leading: 2, trailing: 2)
        }
        // Italic matches overlapping a bold span are its inner markers.
        italicRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match,
                  !boldMatches.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { return }
            delimiters(match.range, leading: 1, trailing: 1)
        }
        codeSpanRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            delimiters(match.range, leading: 1, trailing: 1)
        }
        wikilinkRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            delimiters(match.range, leading: 2, trailing: 2)
        }
        // "[label](url)": hide "[" and "](url)", keep the label.
        linkRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let match else { return }
            ranges.append(NSRange(location: offset + match.range.location, length: 1))
            let close = ns.range(of: "]", options: [], range: match.range)
            if close.location != NSNotFound {
                ranges.append(NSRange(location: offset + close.location,
                                      length: NSMaxRange(match.range) - close.location))
            }
        }
        if let heading = headingRegex.firstMatch(in: line, range: full) {
            ranges.append(NSRange(location: offset + heading.range.location,
                                  length: heading.range.length))
        }
        // Bullet lines: the bullet (and task marker) render as a checkbox /
        // dash glyph in the gutter, so the raw prefix hides too.
        if let prefix = renderableBulletPrefix(inLine: line) {
            ranges.append(NSRange(location: offset + prefix.location, length: prefix.length))
        }
        return ranges
    }
}
