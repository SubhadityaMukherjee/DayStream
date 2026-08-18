import SwiftUI

/// Editor sheet for a `[[wikilink]]` page: content editor plus Logseq-style
/// "Linked References" — every line across the vault that mentions this page.
struct PageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let pageName: String

    @State private var text = ""
    @State private var loaded = false
    @State private var pageURL: URL?
    @State private var isDirty = false
    @State private var mentions: [VaultStore.Mention] = []
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pageName)
                    .font(.system(size: 15, weight: .semibold))
                if isDirty {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()

                if let isEmpty = pageTextIsEmpty, isEmpty {
                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this empty page")
                    .confirmationDialog(
                        "Delete the empty page “\(pageName)”?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Page", role: .destructive) {
                            deleteEmptyPage()
                        }
                    }
                }

                Button("Close") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownEditorView(text: $text, imageImporter: imageImporter) { newText in
                        isDirty = true
                        scheduleSave()
                        refreshMentions(newText: newText)
                    } onCommit: {
                        save()
                        dismiss()
                    }
                    .padding(.horizontal, 8)

                    mentionsSection
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let store = appModel.store {
                let url = store.pageURL(named: pageName, createIfMissing: true)
                pageURL = url
                text = url.map { store.pageText(at: $0) } ?? ""
                refreshMentions(newText: text)
            }
        }
        .onDisappear {
            save()
        }
    }

    private var pageTextIsEmpty: Bool? {
        guard let pageURL else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Linked references

    @ViewBuilder
    private var mentionsSection: some View {
        if !mentions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linked References (\(mentions.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(mentions) { mention in
                    mentionRow(mention)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.4))
            )
        }
    }

    private func mentionRow(_ mention: VaultStore.Mention) -> some View {
        Button {
            openMention(mention)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mention.date != nil
                     ? Self.dayFormatter.string(from: mention.date!)
                     : mention.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                MarkdownText(content: mention.lineText)
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func openMention(_ mention: VaultStore.Mention) {
        save()
        if let date = mention.date {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                appModel.reveal(day: date)
            }
        } else {
            appModel.openPage = AppModel.PageRef(name: mention.title)
        }
    }

    private func refreshMentions(newText: String) {
        guard let store = appModel.store else { return }
        mentions = store.mentions(of: pageName)
    }

    // MARK: - Saving / deletion

    @State private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { save() }
        }
    }

    private func save() {
        guard let store = appModel.store else { return }
        let url = pageURL ?? store.pageURL(named: pageName, createIfMissing: true)
        guard let url else { return }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if current != text {
            store.write(text: text, to: url)
            isDirty = false
            refreshMentions(newText: text)
        }
    }

    private func deleteEmptyPage() {
        guard let store = appModel.store, let url = pageURL else { return }
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: url)
        store.reload()
        dismiss()
    }

    private func imageImporter(_ data: Data, name: String?) -> String? {
        appModel.store?.importImage(data, originalName: name)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Sheet for creating a brand-new page note.
struct NewNoteSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("New Page")
                .font(.system(size: 14, weight: .semibold))
            TextField("Page name (e.g. Research Ideas)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Create & Edit", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Create the markdown file in the vault right away — it must exist on
        // disk even if the editor sheet is never opened or saved into.
        if let url = appModel.store?.pageURL(named: trimmed, createIfMissing: true) {
            appModel.store?.write(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "", to: url)
        }
        appModel.showNewNote = false
        appModel.openPage = AppModel.PageRef(name: trimmed)
        dismiss()
    }
}
