import Foundation

/// Read-only merged view over a range of daily notes: sections merge under
/// their headings, repeated tasks collapse (DONE wins anywhere it appears),
/// and bookkeeping property lines (`added::`, `completed::`, `id::`, …) are
/// dropped. Produces both a render tree and standalone markdown; nothing is
/// ever written back to the vault.
enum DaySummary {
    struct Node: Equatable {
        var indent: Int
        var isBullet: Bool
        /// TODO/DOING/DONE/LATER/NOW, nil for plain bullets and text.
        var marker: String?
        var content: String
        /// Non-property continuation lines under the block, verbatim.
        var bodyLines: [String]
        var children: [Node]
    }

    struct Section: Identifiable {
        var id: String { headingKey }
        /// Normalized heading text; the preamble (content before any
        /// heading) uses a private key that can't collide.
        let headingKey: String
        /// Raw heading line (`## [[ADMIN]]`), nil for the preamble.
        let heading: String?
        var nodes: [Node]
    }

    struct Result {
        let startDate: Date
        let endDate: Date
        let dayCount: Int
        let sections: [Section]
        let markdown: String

        var rangeTitle: String {
            DaySummary.rangeTitle(startDate, endDate)
        }

        var suggestedFilename: String {
            "Summary \(Self.isoDay.string(from: startDate)) to \(Self.isoDay.string(from: endDate)).md"
        }

        private static let isoDay: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
    }

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static func rangeTitle(_ start: Date, _ end: Date) -> String {
        "\(rangeFormatter.string(from: start)) – \(rangeFormatter.string(from: end))"
    }

    private static let preambleKey = "\u{0}preamble"
    private static let propertyRegex = try! NSRegularExpression(pattern: #"^\s*[A-Za-z][A-Za-z0-9_-]*::"#)

    /// `entries` are (day, note text) pairs; they are processed oldest
    /// first so first-seen order and DONE-wins merging are chronological.
    static func make(entries: [(date: Date, text: String)], endDate: Date) -> Result {
        var order: [String] = []
        var sections: [String: Section] = [:]
        let sorted = entries.sorted { $0.date < $1.date }

        for entry in sorted {
            for chunk in splitIntoChunks(entry.text) {
                let key = chunk.heading.map { BlockTree.normalize($0) } ?? preambleKey
                if sections[key] == nil {
                    sections[key] = Section(headingKey: key, heading: chunk.heading, nodes: [])
                    order.append(key)
                }
                for block in BlockTree.parse(chunk.text) {
                    merge(node(from: block), into: &sections[key]!.nodes)
                }
            }
        }

        let ordered = order.compactMap { sections[$0] }.filter { !$0.nodes.isEmpty }
        return Result(
            startDate: sorted.first?.date ?? endDate,
            endDate: endDate,
            dayCount: sorted.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            sections: ordered,
            markdown: markdown(sections: ordered, startDate: sorted.first?.date ?? endDate, endDate: endDate))
    }

    /// Splits a note into (heading, body) chunks. Line-level, not
    /// block-level: the outliner parser attaches a heading that follows an
    /// open bullet to that bullet as body text, so tree walking alone would
    /// miss the section boundary.
    private static func splitIntoChunks(_ text: String) -> [(heading: String?, text: String)] {
        var chunks: [(heading: String?, lines: [String], hasContent: Bool)] = []
        var heading: String? = nil
        var lines: [String] = []
        var hasContent = false
        for line in text.components(separatedBy: "\n") {
            if let h = headingLineText(line) {
                if hasContent || heading != nil {
                    chunks.append((heading, lines, hasContent))
                }
                heading = h
                lines = []
                hasContent = false
            } else {
                lines.append(line)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { hasContent = true }
            }
        }
        if hasContent || heading != nil {
            chunks.append((heading, lines, hasContent))
        }
        return chunks.map { ($0.heading, $0.lines.joined(separator: "\n")) }
    }

    /// `#{1,6} heading` line, if it is one.
    private static func headingLineText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: "^#{1,6}\\s+\\S", options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private static func isPropertyLine(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return propertyRegex.firstMatch(in: line, range: full) != nil
    }

    private static func node(from block: Block) -> Node {
        Node(
            indent: block.indent,
            isBullet: block.isBullet,
            marker: block.marker,
            content: block.isBullet
                ? block.content
                : block.content.trimmingCharacters(in: .whitespaces),
            bodyLines: block.rawLines.dropFirst().filter {
                !isPropertyLine($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty
            },
            children: block.children.map(node(from:)))
    }

    /// Appends `node`, collapsing duplicates by normalized content (bullets
    /// only collapse with bullets): a DONE occurrence anywhere marks the
    /// kept task done, and children and body lines merge in (body lines of
    /// later duplicates would otherwise be lost).
    private static func merge(_ node: Node, into nodes: inout [Node]) {
        let key = BlockTree.normalize(node.content)
        if !key.isEmpty,
           let idx = nodes.firstIndex(where: {
               $0.isBullet == node.isBullet && BlockTree.normalize($0.content) == key
           }) {
            if node.marker == "DONE" { nodes[idx].marker = "DONE" }
            for line in node.bodyLines where !nodes[idx].bodyLines.contains(line) {
                nodes[idx].bodyLines.append(line)
            }
            for child in node.children {
                merge(child, into: &nodes[idx].children)
            }
        } else {
            nodes.append(node)
        }
    }

    private static func markdown(sections: [Section], startDate: Date, endDate: Date) -> String {
        var lines: [String] = []
        for section in sections {
            if !lines.isEmpty { lines.append("") }
            if let heading = section.heading {
                lines.append(heading)
            }
            append(section.nodes, top: true, into: &lines)
        }
        return (["# Summary: \(rangeTitle(startDate, endDate))", ""] + lines)
            .joined(separator: "\n") + "\n"
    }

    private static func append(_ nodes: [Node], top: Bool, into out: inout [String]) {
        for (i, n) in nodes.enumerated() {
            if top && i > 0 { out.append("") }
            if n.isBullet {
                out.append(String(repeating: "\t", count: n.indent)
                    + "- " + (n.marker.map { "\($0) " } ?? "") + n.content)
            } else {
                out.append(String(repeating: "\t", count: n.indent) + n.content)
            }
            out.append(contentsOf: n.bodyLines)
            append(n.children, top: false, into: &out)
        }
    }
}
