import SwiftUI

/// Renders one block (bullet, checkbox, content, properties) and its children.
struct BlockRowView: View {
    @Environment(AppSettings.self) private var settings
    let block: Block
    let file: VaultFile
    let store: VaultStore

    private static let indentWidth: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            indentRails

            markerView
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if !block.isBullet, block.content.hasPrefix("#") {
                    MarkdownText(content: block.content)
                        .font(settings.headingFont(level: headingLevel))
                } else {
                    MarkdownText(
                        content: block.content,
                        strikethrough: block.todoState == .done,
                        color: block.todoState == .done ? .secondary : .primary
                    )
                    .font(settings.streamFont)
                }
                propertyBadges
                bodyLines
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)

        ForEach(block.children) { child in
            BlockRowView(block: child, file: file, store: store)
        }
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

    @ViewBuilder
    private var markerView: some View {
        switch block.todoState {
        case .open:
            Button {
                store.toggleTodo(in: file, block: block, syncAcrossNotes: settings.syncTodosAcrossNotes)
            } label: {
                Image(systemName: "square")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark as done (⌘⏎ in editor toggles too)")
        case .done:
            Button {
                store.toggleTodo(in: file, block: block, syncAcrossNotes: settings.syncTodosAcrossNotes)
            } label: {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Mark as todo")
        case .none:
            if block.isBullet {
                Text(Self.bulletSymbol(level: block.indent))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }

    /// Classic outliner bullets that cycle with depth: •, ◦, ▪.
    private static func bulletSymbol(level: Int) -> String {
        ["•", "◦", "▪"][level % 3]
    }

    @ViewBuilder
    private var propertyBadges: some View {
        if !block.properties.isEmpty {
            HStack(spacing: 6) {
                ForEach(block.properties, id: \.key) { prop in
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
                    .background(
                        Capsule().fill(propertyColor(prop).opacity(0.12))
                    )
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
        // Body lines beyond the first raw line (first is the bullet itself).
        let extra = block.rawLines.dropFirst()
        if !extra.isEmpty {
            ForEach(Array(extra.enumerated()), id: \.offset) { _, line in
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
