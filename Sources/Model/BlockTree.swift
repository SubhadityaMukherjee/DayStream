import Foundation

/// Todo state derived from Logseq markers (`TODO`/`DOING`/`DONE`/`LATER`/`NOW`)
/// or legacy `Status:: Todo` / `Status:: Done` property lines.
enum TodoState {
    case open
    case done
    case none
}

struct BlockProperty {
    let key: String
    let value: String
}

/// One outliner block: a bullet line plus its continuation body lines and
/// property lines (`Key:: value`), plus child blocks at deeper indentation.
struct Block: Identifiable {
    /// Stable identity: the block's line index in the file. Survives re-parses
    /// (e.g. a todo toggle rewrites one line), so SwiftUI updates only the
    /// affected rows instead of rebuilding every block in the day.
    var id: String { "line-\(lineIndex)" }
    /// Index of the bullet line in the original file, for surgical edits.
    let lineIndex: Int
    let indent: Int
    let isBullet: Bool
    /// `TODO`, `DOING`, `DONE`, `LATER`, `NOW` or nil.
    let marker: String?
    /// Content after `- ` and the marker.
    let content: String
    /// This block's own raw lines (bullet line first, then body/property lines).
    var rawLines: [String]
    var properties: [BlockProperty]
    var children: [Block]

    var statusProperty: BlockProperty? {
        properties.first { $0.key.lowercased() == "status" }
    }

    var todoState: TodoState {
        if let marker {
            switch marker {
            case "DONE": return .done
            case "TODO", "DOING", "LATER", "NOW": return .open
            default: return .none
            }
        }
        if let status = statusProperty {
            let v = status.value.trimmingCharacters(in: .whitespaces).lowercased()
            switch v {
            case "done": return .done
            case "todo", "doing", "in progress", "waiting": return .open
            default: return .none
            }
        }
        return .none
    }
}

enum BlockTree {

    // MARK: - Parsing

    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        // Stack of (indent, index-into-roots-recursively). We build with a flat
        // array + parent pointers, then materialize the tree.
        struct Entry {
            var block: Block
            var children: [Int] = []
        }
        var entries: [Entry] = []
        var stack: [Int] = [] // indices into entries, innermost last

        func indentUnits(_ line: String) -> Int {
            var units = 0
            var spaces = 0
            for ch in line {
                if ch == "\t" {
                    units += 1
                    spaces = 0
                } else if ch == " " {
                    spaces += 1
                    if spaces == 4 { units += 1; spaces = 0 }
                } else {
                    break
                }
            }
            return units
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }

            if let prop = parseProperty(trimmed), !trimmed.hasPrefix("- ") {
                // Property line: attaches to the most recent bullet block.
                if let last = stack.last, entries.indices.contains(last) {
                    entries[last].block.properties.append(prop)
                    entries[last].block.rawLines.append(line)
                }
                i += 1
                continue
            }

            if let bullet = parseBullet(line) {
                while let top = stack.last, entries[top].block.indent >= bullet.indent {
                    stack.removeLast()
                }
                let entry = Entry(block: Block(
                    lineIndex: i,
                    indent: bullet.indent,
                    isBullet: true,
                    marker: bullet.marker,
                    content: bullet.content,
                    rawLines: [line],
                    properties: [],
                    children: []
                ))
                entries.append(entry)
                let idx = entries.count - 1
                if let parent = stack.last {
                    entries[parent].children.append(idx)
                }
                stack.append(idx)
                i += 1
                continue
            }

            // Plain continuation/heading line: attach to innermost block as body,
            // or to its own root text block if no bullet is open.
            if let last = stack.last, entries.indices.contains(last) {
                entries[last].block.rawLines.append(line)
            } else {
                let entry = Entry(block: Block(
                    lineIndex: i,
                    indent: indentUnits(line),
                    isBullet: false,
                    marker: nil,
                    content: trimmed,
                    rawLines: [line],
                    properties: [],
                    children: []
                ))
                entries.append(entry)
            }
            i += 1
        }

        // Materialize tree: roots are entries nobody references as a child.
        var isChild = Set<Int>()
        for e in entries {
            for c in e.children { isChild.insert(c) }
        }
        func materialize(_ idx: Int) -> Block {
            var e = entries[idx]
            e.block.children = e.children.map(materialize)
            return e.block
        }
        return entries.indices
            .filter { !isChild.contains($0) }
            .map(materialize)
    }

    private static func parseProperty(_ trimmed: String) -> BlockProperty? {
        guard let r = trimmed.range(of: "^([A-Za-z][A-Za-z0-9_-]*)::(.*)$", options: .regularExpression) else {
            return nil
        }
        let matched = String(trimmed[r])
        guard let sep = matched.range(of: "::") else { return nil }
        let key = String(matched[matched.startIndex..<sep.lowerBound])
        let value = String(matched[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return BlockProperty(key: key, value: value)
    }

    private static func parseBullet(_ line: String) -> (indent: Int, marker: String?, content: String)? {
        let units = leadingWhitespaceUnits(line)
        var rest = String(line.drop { $0 == "\t" || $0 == " " })
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return nil }
        rest = String(rest.dropFirst(2))
        var marker: String?
        var content = rest
        for m in ["TODO", "DOING", "DONE", "LATER", "NOW"] {
            let withSpace = m + " "
            if rest.hasPrefix(withSpace) {
                marker = m
                content = String(rest.dropFirst(withSpace.count))
                break
            }
            if rest == m {
                marker = m
                content = ""
                break
            }
        }
        return (units, marker, content)
    }

    static func leadingWhitespaceUnits(_ line: String) -> Int {
        var units = 0
        var spaces = 0
        for ch in line {
            if ch == "\t" {
                units += 1
                spaces = 0
            } else if ch == " " {
                spaces += 1
                if spaces == 4 { units += 1; spaces = 0 }
            } else {
                break
            }
        }
        return units
    }

    /// Public wrapper over the private bullet parser for line-level helpers
    /// (timestamp stamping, save normalization).
    static func bulletInfo(_ line: String) -> (indent: Int, marker: String?, content: String)? {
        parseBullet(line)
    }

    // MARK: - Todo toggling (surgical, preserves all other bytes)

    /// Returns the file text with the given block's todo state flipped.
    static func toggledFileText(_ text: String, blockLineIndex: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(blockLineIndex) else { return text }
        let line = lines[blockLineIndex]

        if let bullet = parseBullet(line), bullet.marker != nil {
            let old = bullet.marker!
            let new = old == "DONE" ? "TODO" : "DONE"
            if let r = line.range(of: old) {
                lines[blockLineIndex] = line.replacingCharacters(in: r, with: new)
                return lines.joined(separator: "\n")
            }
        }

        // Status-property style: find the `Status::` line following this block's bullet.
        var j = blockLineIndex + 1
        while lines.indices.contains(j) {
            let l = lines[j]
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { break }
            if let r = trimmed.range(of: "^Status::\\s*(\\S*)(.*)$", options: .regularExpression) {
                let matched = String(trimmed[r])
                if let sep = matched.range(of: "::") {
                    let after = String(matched[sep.upperBound...])
                    let value = after.trimmingCharacters(in: .whitespaces)
                    let flipped = value.lowercased() == "done" ? "Todo" : "Done"
                    // Preserve leading whitespace and key, replace value.
                    let lead = String(l.prefix(while: { $0 == "\t" || $0 == " " }))
                    let afterSeparator = after.drop { $0 == " " }
                    let trailing = afterSeparator.drop { $0 != " " }
                    let newTail = String(trailing)
                    lines[j] = lead + "Status:: " + flipped + newTail
                    return lines.joined(separator: "\n")
                }
            }
            j += 1
        }
        return text
    }

    // MARK: - Cross-note todo syncing

    /// Rewrites every todo block whose normalized content matches `key` so its
    /// state becomes `state`. Returns nil when nothing needed changing.
    /// Single parse pass + surgical in-place line edits, so it stays fast even
    /// on large files (edits never change line counts, so line indices hold).
    static func syncedText(_ text: String, key: String, to state: TodoState) -> String? {
        guard !key.isEmpty else { return nil }
        // Cheap prefilter: normalization only lowercases, collapses whitespace
        // and trims edge punctuation, so every word of the key must appear
        // (lowercased) verbatim in the raw text. Skip parsing when it doesn't.
        guard let probe = key.components(separatedBy: " ").filter({ !$0.isEmpty })
            .max(by: { $0.count < $1.count }) else { return nil }
        guard text.lowercased().contains(probe) else { return nil }

        var lineIndices: [Int] = []
        func walk(_ nodes: [Block]) {
            for b in nodes {
                if b.todoState != .none, b.todoState != state, normalize(b.content) == key {
                    lineIndices.append(b.lineIndex)
                }
                walk(b.children)
            }
        }
        walk(parse(text))
        guard !lineIndices.isEmpty else { return nil }

        var current = text
        var changed = false
        for idx in lineIndices {
            let updated = toggledFileText(current, blockLineIndex: idx)
            if updated != current {
                current = updated
                changed = true
            }
        }
        return changed ? current : nil
    }

    // MARK: - Carry-forward helpers

    /// Raw lines for this block's subtree, skipping DONE subtrees.
    /// `Status::`-style todo blocks keep their property lines so they stay todos.
    static func renderedSubtree(_ block: Block) -> [String] {
        var out = block.rawLines
        for child in block.children {
            if child.todoState == .done { continue }
            out += renderedSubtree(child)
        }
        return out
    }

    /// Every non-empty line of the block's subtree (children included),
    /// trimmed, capped at `maxLines` with an ellipsis marker. Used for
    /// linked-reference previews.
    static func subtreeLines(_ block: Block, maxLines: Int) -> [String] {
        var lines: [String] = []
        func rec(_ b: Block) {
            lines.append(contentsOf: b.rawLines)
            b.children.forEach(rec)
        }
        rec(block)
        let trimmed = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if trimmed.count > maxLines {
            return Array(trimmed.prefix(maxLines)) + ["…"]
        }
        return trimmed
    }

    /// Recursively collects open tasks with their plain (non-task) ancestor chains.
    static func collectOpenTasks(
        _ nodes: [Block],
        ancestors: [Block],
        into out: inout [(task: Block, path: [Block])]
    ) {
        for node in nodes {
            switch node.todoState {
            case .done:
                continue
            case .open:
                out.append((node, ancestors))
            case .none:
                collectOpenTasks(node.children, ancestors: ancestors + [node], into: &out)
            }
        }
    }

    static func allContentKeys(_ blocks: [Block]) -> Set<String> {
        var keys = Set<String>()
        func walk(_ nodes: [Block]) {
            for n in nodes {
                keys.insert(normalize(n.content))
                walk(n.children)
            }
        }
        walk(blocks)
        return keys
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".;:,!?"))
    }
}
