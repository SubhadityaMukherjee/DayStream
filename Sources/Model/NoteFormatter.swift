import Foundation

/// Timestamp property helpers (`added::` / `completed::`), save-and-quit
/// auto-formatting (consistent tabs/bullets/linebreaks, block spacing),
/// and human-readable durations for finished tasks.
enum NoteFormatter {
    static let timestampFormat = "yyyy-MM-dd HH:mm"

    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = timestampFormat
        return f
    }

    static func timestamp(_ date: Date) -> String {
        stampFormatter().string(from: date)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        stampFormatter().date(from: s.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Durations

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let m = seconds / 60
        let h = m / 60
        let d = h / 24
        if d > 0 { return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h" }
        if h > 0 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    // MARK: - Save/quit auto-formatting

    /// Cleanup applied whenever the editor is saved or closed: whitespace
    /// and bullet markers normalized to house style, blank lines collapsed,
    /// empty bullets dropped, blank lines kept between top-level blocks of
    /// different kinds (headings, text, `[[wikilink]]` groups, list groups,
    /// fenced code), and open tasks in today's note stamped with `added::`
    /// so completion durations can be shown later. Fenced code blocks pass
    /// through with their content byte-identical.
    static func normalizedForSave(_ text: String, isToday: Bool, now: Date) -> String {
        var out = removingEmptyBullets(text)
        out = normalizingWhitespace(out)
        out = collapsingBlankLines(out)
        if isToday {
            out = stampingAddedTimestamps(out, at: now)
        }
        out = spacingWikilinkGroups(out)
        out = spacingBlockBoundaries(out)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    /// Drops lines that are nothing but a bare `-` / `*` bullet — never
    /// inside fenced code blocks, where a bare bullet can be content.
    static func removingEmptyBullets(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if BlockTree.fenceMarker(trimmed) != nil { inFence.toggle() }
                if inFence { return true }
                return line.range(of: #"^\s*[-*]\s*$"#, options: .regularExpression) == nil
            }
            .joined(separator: "\n")
    }

    /// House style, per line, outside fenced code blocks:
    /// leading whitespace becomes tabs (every 4 spaces = one tab, matching
    /// the parser's indent units), `*` bullets become `-`, exactly one space
    /// after the bullet marker / heading hashes / `Key::` separator, and
    /// trailing whitespace is dropped. Fence content is untouched.
    static func normalizingWhitespace(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if BlockTree.fenceMarker(trimmed) != nil {
                inFence.toggle()
                return trimmed
            }
            if inFence { return line }
            guard !trimmed.isEmpty else { return "" }

            let indentUnits = BlockTree.leadingWhitespaceUnits(line)
            let indent = String(repeating: "\t", count: indentUnits)
            let body = String(line.drop { $0 == "\t" || $0 == " " })

            if let r = body.range(of: #"^([-*])[ \t]+"#, options: .regularExpression) {
                return indent + "- " + String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let r = trimmed.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) {
                let hashes = trimmed[trimmed.startIndex..<r.upperBound].trimmingCharacters(in: .whitespaces)
                return hashes + " " + String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let r = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9_-]*::[ \t]*"#, options: .regularExpression) {
                let separator = trimmed[trimmed.startIndex..<r.upperBound].trimmingCharacters(in: .whitespaces) + " "
                let value = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                return indent + separator + value
            }
            return indent + body.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Three or more consecutive newlines (two or more blank lines) collapse
    /// to a single blank line. Blank runs inside fenced code blocks are left
    /// alone — code can be whitespace-sensitive.
    static func collapsingBlankLines(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        var lastWasBlank = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if BlockTree.fenceMarker(trimmed) != nil { inFence.toggle() }
            let blank = !inFence && trimmed.isEmpty
            if blank, lastWasBlank { continue }
            out.append(line)
            lastWasBlank = blank
        }
        return out.joined(separator: "\n")
    }

    /// Ensures a blank line between a top-level block that starts with a
    /// `[[wikilink]]` (including its indented children) and the preceding
    /// non-blank line. Never fires inside fenced code blocks.
    static func spacingWikilinkGroups(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if BlockTree.fenceMarker(trimmed) != nil { inFence.toggle() }
            if !inFence,
               isTopLevelWikilinkBullet(line),
               let last = out.last,
               !last.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static func isTopLevelWikilinkBullet(_ line: String) -> Bool {
        guard BlockTree.leadingWhitespaceUnits(line) == 0 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return false }
        let content = String(trimmed.dropFirst(2))
        guard content.hasPrefix("[[") else { return false }
        return !WikiName.wikilinkTargets(in: content).isEmpty
    }

    /// Keeps one blank line between top-level blocks of different kinds —
    /// headings, plain text, bullet groups, wikilink groups, fenced code
    /// blocks. Bullets that sit together stay together (a group); blank lines
    /// the author already put between blocks are preserved (never doubled or
    /// removed); blank lines inside fences are untouched.
    static func spacingBlockBoundaries(_ text: String) -> String {
        enum Kind { case heading, bullet, text, code }

        func classify(_ line: String) -> Kind? {
            guard BlockTree.leadingWhitespaceUnits(line) == 0 else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.range(of: #"^[A-Za-z][A-Za-z0-9_-]*::"#, options: .regularExpression) == nil
            else { return nil }
            if trimmed.hasPrefix("#") { return .heading }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return .bullet }
            return .text
        }

        /// True when a blank line belongs between adjacent top-level blocks.
        /// Code blocks always separate from neighbors; stacked headings stay
        /// tight (they read as one unit); text separates from bullets.
        func needsBlank(_ a: Kind, _ b: Kind) -> Bool {
            if a == .code || b == .code { return true }
            if a == .heading, b == .heading { return false }
            if a == .heading || b == .heading { return true }
            return (a == .text) != (b == .text)
        }

        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var prevKind: Kind?
        var separated = true // top of file: nothing to separate from

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                separated = true
                out.append(line)
                i += 1
                continue
            }

            // A fence marker consumes its whole run (to the matching close,
            // or the end of the note) as one block, blanks inside included.
            if BlockTree.fenceMarker(trimmed) != nil {
                var end = i + 1
                while end < lines.count {
                    let inner = lines[end].trimmingCharacters(in: .whitespaces)
                    if BlockTree.fenceMarker(inner) != nil {
                        end += 1
                        break
                    }
                    end += 1
                }
                if let prev = prevKind, !separated, needsBlank(prev, .code) {
                    out.append("")
                }
                out.append(contentsOf: lines[i..<end])
                prevKind = .code
                separated = false
                i = end
                continue
            }

            guard let kind = classify(line) else {
                // Indented child or property line: belongs to the block above.
                out.append(line)
                i += 1
                continue
            }

            // Collect the block: start line, indented lines, property lines,
            // and (for text blocks) following unindented text lines — those
            // are paragraph continuations. Fence lines never join a block;
            // they are handled as their own blocks above.
            var blockEnd = i + 1
            while blockEnd < lines.count {
                let next = lines[blockEnd]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if BlockTree.fenceMarker(nextTrimmed) != nil { break }
                let indented = BlockTree.leadingWhitespaceUnits(next) > 0
                let isProperty = next.range(of: #"^\s*[A-Za-z][A-Za-z0-9_-]*::"#, options: .regularExpression) != nil
                if indented || isProperty {
                    blockEnd += 1
                    continue
                }
                if kind == .text, classify(next) == .text {
                    blockEnd += 1
                    continue
                }
                break
            }

            if let prev = prevKind, !separated, needsBlank(prev, kind) {
                out.append("")
            }
            out.append(contentsOf: lines[i..<blockEnd])
            prevKind = kind
            separated = false
            i = blockEnd
        }
        return out.joined(separator: "\n")
    }

    // MARK: - `added::` stamping

    /// Adds an `added:: <timestamp>` property line under every open-marker
    /// task that doesn't already have one. Existing stamps are never
    /// rewritten, so re-saving an old note can't falsify history.
    static func stampingAddedTimestamps(_ text: String, at date: Date) -> String {
        var lines = text.components(separatedBy: "\n")
        var insertions: [(index: Int, line: String)] = []
        for (i, line) in lines.enumerated() {
            guard let bullet = BlockTree.bulletInfo(line),
                  let marker = bullet.marker,
                  marker != "DONE",
                  blockHasProperty(lines, bulletIndex: i, key: "added") == false
            else { continue }
            let indent = String(repeating: "\t", count: bullet.indent + 1)
            insertions.append((i + 1, indent + "added:: " + timestamp(date)))
        }
        // Insert bottom-up so earlier indices stay valid.
        for insertion in insertions.reversed() {
            lines.insert(insertion.line, at: insertion.index)
        }
        return lines.joined(separator: "\n")
    }

    /// True when the block starting at `bulletIndex` carries `Key:: value`.
    private static func blockHasProperty(_ lines: [String], bulletIndex: Int, key: String) -> Bool {
        guard lines.indices.contains(bulletIndex) else { return false }
        var j = bulletIndex + 1
        while lines.indices.contains(j) {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { break }
            if let r = trimmed.range(of: "^([A-Za-z][A-Za-z0-9_-]*)::", options: .regularExpression) {
                let keyWithSep = String(trimmed[trimmed.startIndex..<r.upperBound])
                if keyWithSep.lowercased().hasPrefix(key.lowercased() + "::") {
                    return true
                }
            }
            j += 1
        }
        return false
    }

    // MARK: - `completed::` stamping

    /// After a toggle to DONE, records when the task was completed: inserts a
    /// `completed::` property line right under the bullet, or updates the
    /// existing one in place (a task re-done later gets the new time).
    static func withCompletionStamp(_ text: String, blockLineIndex: Int, at date: Date) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(blockLineIndex),
              let bullet = BlockTree.bulletInfo(lines[blockLineIndex])
        else { return text }

        let value = timestamp(date)
        var j = blockLineIndex + 1
        while lines.indices.contains(j) {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { break }
            if trimmed.lowercased().hasPrefix("completed::") {
                let indent = String(lines[j].prefix(while: { $0 == "\t" || $0 == " " }))
                lines[j] = indent + "completed:: " + value
                return lines.joined(separator: "\n")
            }
            j += 1
        }
        let indent = String(repeating: "\t", count: bullet.indent + 1)
        lines.insert(indent + "completed:: " + value, at: blockLineIndex + 1)
        return lines.joined(separator: "\n")
    }
}
