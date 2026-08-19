import Foundation

/// Timestamp property helpers (`added::` / `completed::`), ⌘S save
/// normalization (drop empty bullets, space out top-level wikilink groups),
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

    // MARK: - ⌘S save normalization

    /// Cleanup applied on explicit save-and-quit: empty bullets dropped, a
    /// blank line kept between top-level `[[wikilink]]` groups (and their
    /// children) and whatever follows, open tasks in today's note stamped
    /// with `added::` so completion durations can be shown later.
    static func normalizedForSave(_ text: String, isToday: Bool, now: Date) -> String {
        var out = removingEmptyBullets(text)
        if isToday {
            out = stampingAddedTimestamps(out, at: now)
        }
        out = spacingWikilinkGroups(out)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    /// Drops lines that are nothing but a bare `-` / `*` bullet.
    static func removingEmptyBullets(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                line.range(of: #"^\s*[-*]\s*$"#, options: .regularExpression) == nil
            }
            .joined(separator: "\n")
    }

    /// Ensures a blank line between a top-level block that starts with a
    /// `[[wikilink]]` (including its indented children) and the preceding
    /// non-blank line.
    static func spacingWikilinkGroups(_ text: String) -> String {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if isTopLevelWikilinkBullet(line),
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
