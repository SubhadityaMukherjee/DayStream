import SwiftUI

/// Renders one block (bullet, checkbox, content, properties) and its children.
struct BlockRowView: View {
    @Environment(AppSettings.self) private var settings
    let block: Block
    let file: VaultFile
    let store: VaultStore
    /// Overrides the default toggle (pages refresh their own text after it).
    var onToggle: ((Block) -> Void)? = nil

    private static let indentWidth: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            indentRails

            markerView
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if isWholeBlockCode {
                    wholeBlockCode()
                } else if !block.isBullet, block.content.hasPrefix("#") {
                    MarkdownText(content: block.content)
                        .font(settings.headingFont(level: headingLevel))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        MarkdownText(
                            content: block.content,
                            strikethrough: block.todoState == .done,
                            color: block.todoState == .done ? .secondary : .primary
                        )
                        .font(settings.streamFont)
                        durationBadge
                    }
                }
                propertyBadges
                bodyLines
            }

            Spacer(minLength: 0)
        }
        // A [[wikilink]] row heads the sublist under it — extra space above
        // separates it from the previous group so sections read clearly.
        .padding(.top, isWikilinkHeader ? 9 : 1)
        .padding(.bottom, 1)

        ForEach(block.children) { child in
            BlockRowView(block: child, file: file, store: store, onToggle: onToggle)
        }
    }

    private func toggle() {
        if let onToggle {
            onToggle(block)
        } else {
            store.toggleTodo(in: file, block: block, syncAcrossNotes: settings.syncTodosAcrossNotes)
        }
    }

    /// `added::` / `completed::` are internal bookkeeping for durations,
    /// `id::` is a Logseq-generated identifier — none are user content.
    private var hiddenPropertyKeys: Set<String> {
        ["added", "completed", "id"]
    }

    /// Outliner-style vertical guide rails, one per ancestor indent level.
    /// Each row draws its own segment so stacked rows read as a continuous rail.
    @ViewBuilder
    private var indentRails: some View {
        if block.indent > 0 {
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<block.indent, id: \.self) { _ in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 1)
                            .padding(.vertical, -2)
                    }
                    .frame(width: Self.indentWidth)
                }
            }
        }
    }

    private var headingLevel: Int {
        block.content.prefix(while: { $0 == "#" }).count
    }

    private var isWikilinkHeader: Bool {
        block.content.trimmingCharacters(in: .whitespaces).hasPrefix("[[")
    }

    @ViewBuilder
    private var markerView: some View {
        switch block.todoState {
        case .open:
            Button(action: toggle) {
                Image(systemName: "square")
                    .font(.system(size: 13.5, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Mark as done (⌘⏎ in editor toggles too)")
        case .done:
            Button(action: toggle) {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.green)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(durationHelp ?? "Mark as todo")
        case .none:
            if block.isBullet {
                // Markdown-style dash, matching the source text; same font
                // size as the content line so it baseline-aligns naturally.
                Text("-")
                    .font(.system(size: settings.fontSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18, alignment: .center)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Completion duration

    /// Time a finished task took, from its `added::` stamp to `completed::`.
    @ViewBuilder
    private var durationBadge: some View {
        if let duration = completionDuration {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 8.5))
                Text(duration)
                    .monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .tintedGlassBackground(Color.green.opacity(0.14), in: Capsule())
            .help(durationHelp ?? "")
        }
    }

    private var completionDuration: String? {
        guard block.todoState == .done,
              let added = propertyValue("added"),
              let completed = propertyValue("completed"),
              let a = NoteFormatter.parseTimestamp(added),
              let c = NoteFormatter.parseTimestamp(completed),
              c >= a
        else { return nil }
        return NoteFormatter.duration(from: a, to: c)
    }

    private var durationHelp: String? {
        guard let added = propertyValue("added"),
              let completed = propertyValue("completed"),
              let a = NoteFormatter.parseTimestamp(added),
              let c = NoteFormatter.parseTimestamp(completed)
        else { return nil }
        return "Added \(Self.helpDateFormatter.string(from: a)) · Completed \(Self.helpDateFormatter.string(from: c))"
    }

    private static let helpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func propertyValue(_ key: String) -> String? {
        block.properties.first { $0.key.lowercased() == key }?.value
    }

    @ViewBuilder
    private var propertyBadges: some View {
        let visible = block.properties.filter { !hiddenPropertyKeys.contains($0.key.lowercased()) }
        if !visible.isEmpty {
            HStack(spacing: 6) {
                // Offset-keyed: hand-edited notes can repeat a key (e.g. two
                // `status::` lines), and duplicate ids would crash the ForEach.
                ForEach(Array(visible.enumerated()), id: \.offset) { _, prop in
                    HStack(spacing: 3) {
                        Text(prop.key)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(prop.value)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(propertyColor(prop))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .tintedGlassBackground(propertyColor(prop).opacity(0.14), in: Capsule())
                }
            }
        }
    }

    private func propertyColor(_ prop: BlockProperty) -> Color {
        if prop.key.lowercased() == "status" {
            let v = prop.value.lowercased()
            if v == "done" { return .green }
            if ["todo", "doing", "in progress", "waiting"].contains(v) { return .orange }
        }
        return .secondary
    }

    @ViewBuilder
    private var bodyLines: some View {
        // Body lines beyond the first raw line (first is the bullet itself),
        // with fenced code blocks rendered as monospaced cards.
        let extra = Array(block.rawLines.dropFirst())
        let segments = BlockTree.bodySegments(extra)
        if !segments.isEmpty {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let language, let lines):
                    CodeBlockView(language: language, code: lines.joined(separator: "\n"))
                case .line(let line):
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, trimmed.range(of: "^[A-Za-z][A-Za-z0-9_-]*::", options: .regularExpression) == nil {
                        MarkdownText(content: trimmed)
                            .font(settings.streamFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A block whose very first line opens a fence (possible for non-bullet
    /// root blocks, e.g. a note that starts with code).
    private var isWholeBlockCode: Bool {
        guard !block.isBullet, let first = block.rawLines.first else { return false }
        return BlockTree.fenceMarker(first.trimmingCharacters(in: .whitespaces)) != nil
    }

    /// Whole block is one fence: re-segment to peel off the language and
    /// the closing marker before rendering.
    @ViewBuilder
    private func wholeBlockCode() -> some View {
        if case .code(let lang, let lines)? = BlockTree.bodySegments(block.rawLines).first {
            CodeBlockView(language: lang, code: lines.joined(separator: "\n"))
        }
    }
}
