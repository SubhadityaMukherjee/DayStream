import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sidebar "Summarize…" flow: pick a start date, then browse the merged,
/// deduplicated content of every note from that day through today. The
/// result is read-only and lives outside the vault; it can be saved as a
/// standalone markdown file or sent through the system share sheet.
struct SummarizeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var startDate = JournalDate.startOfDay(Date().addingTimeInterval(-7 * 86400))
    @State private var result: DaySummary.Result?
    @State private var shareURL: URL?

    var body: some View {
        if let result, let shareURL {
            SummaryDocumentView(result: result, shareURL: shareURL) {
                self.result = nil
                self.shareURL = nil
            } onDone: { dismiss() }
        } else {
            pickerPhase
        }
    }

    private var pickerPhase: some View {
        VStack(spacing: 16) {
            Text("Summarize Notes")
                .font(.system(size: 14, weight: .semibold))
            DatePicker("From", selection: $startDate, in: ...JournalDate.startOfDay(Date()),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
            Text("Merges every note from that day through today — sections fold together, repeated tasks collapse (checked off if done anywhere), and metadata lines are removed. Your notes are never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Create Summary", action: generate)
                    .prominentActionButtonStyle()
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func generate() {
        guard let store = appModel.store else { return }
        let today = JournalDate.startOfDay(Date())
        let start = JournalDate.startOfDay(startDate)
        let entries = store.days
            .filter { $0.date >= start && $0.date <= today }
            .sorted { $0.date < $1.date }
            .compactMap { day in day.editFile.map { (date: day.date, text: $0.text) } }
        let summary = DaySummary.make(entries: entries, endDate: today)
        result = summary
        shareURL = writeTempFile(summary)
    }

    /// The share sheet needs a file URL; write the markdown to a temp file
    /// (never inside the vault).
    private func writeTempFile(_ summary: DaySummary.Result) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(summary.suggestedFilename)
        do {
            try summary.markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// The generated summary: rendered, read-only content plus save/share.
private struct SummaryDocumentView: View {
    let result: DaySummary.Result
    let shareURL: URL
    let onRestart: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.rangeTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(result.dayCount) note\(result.dayCount == 1 ? "" : "s") · merged, duplicates removed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Range…", action: onRestart)
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button("Save…", action: save)
                    .prominentActionButtonStyle()
                Button("Done", action: onDone)
            }
            .padding(12)
            Divider()
            if result.sections.isEmpty {
                ContentUnavailableView(
                    "Nothing to summarize",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("No notes found in this range."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(result.sections) { section in
                            sectionView(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    /// AnyView: the node tree is recursive, and opaque result types can't
    /// be defined in terms of themselves.
    private func sectionView(_ section: DaySummary.Section) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 5) {
            if let heading = section.heading {
                Text(heading)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 8)
            }
            ForEach(Array(section.nodes.enumerated()), id: \.offset) { _, node in
                nodeRow(node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading))
    }

    private func nodeRow(_ node: DaySummary.Node) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Color.clear.frame(width: CGFloat(node.indent) * 16, height: 1)
                if node.isBullet {
                    Image(systemName: symbol(for: node.marker))
                        .font(.system(size: 11))
                        .foregroundStyle(color(for: node.marker))
                        .padding(.top, 2)
                    MarkdownText(content: node.content, strikethrough: node.marker == "DONE")
                } else {
                    MarkdownText(content: node.content)
                }
            }
            ForEach(Array(node.bodyLines.enumerated()), id: \.offset) { _, line in
                Text(line.trimmingCharacters(in: .whitespaces))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(node.indent) * 16 + 18)
            }
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                nodeRow(child)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading))
    }

    private func symbol(for marker: String?) -> String {
        switch marker {
        case "DONE": "checkmark.circle.fill"
        case nil: "circle.dotted"
        default: "circle"
        }
    }

    private func color(for marker: String?) -> Color {
        switch marker {
        case "DONE": .green
        case nil: .secondary
        default: .orange
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = result.suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? result.markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
