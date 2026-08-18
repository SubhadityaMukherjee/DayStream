import SwiftUI

/// Renders one block (bullet, checkbox, content, properties) and its children.
struct BlockRowView: View {
    let block: Block
    let file: VaultFile
    let store: VaultStore

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer().frame(width: CGFloat(block.indent) * 18)

            markerView

            VStack(alignment: .leading, spacing: 2) {
                if !block.isBullet, block.content.hasPrefix("#") {
                    MarkdownText(content: block.content)
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    MarkdownText(
                        content: block.content,
                        strikethrough: block.todoState == .done,
                        color: block.todoState == .done ? .secondary : .primary
                    )
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

    @ViewBuilder
    private var markerView: some View {
        switch block.todoState {
        case .open:
            Button {
                store.toggleTodo(in: file, block: block)
            } label: {
                Image(systemName: "square")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark as done")
        case .done:
            Button {
                store.toggleTodo(in: file, block: block)
            } label: {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Mark as todo")
        case .none:
            if block.isBullet {
                Text("•").foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
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
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
