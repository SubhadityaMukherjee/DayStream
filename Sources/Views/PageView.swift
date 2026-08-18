import SwiftUI

/// Sheet for a `[[wikilink]]` page. Renders like the front page (blocks +
/// linked references); "Edit" switches to the raw markdown editor, where
/// ⎋/⌘S save and return to the rendered view.
struct PageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let pageName: String

    @State private var text = ""
    @State private var loaded = false
    @State private var pageURL: URL?
    @State private var isDirty = false
    @State private var isEditing = false
    @State private var mentions: [VaultStore.Mention] = []
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isEditing {
                        MarkdownEditorView(
                            text: $text,
                            imageImporter: imageImporter,
                            pageNamesProvider: { [weak appModel] in appModel?.store?.allPageNames() ?? [] },
                            onTextChanged: { _ in
                                isDirty = true
                                scheduleSave()
                            },
                            onCommit: {
                                exitEditing()
                            },
                            onSaveCommit: {
                                saveAndQuit()
                            }
                        )
                        .padding(.horizontal, 8)
                    } else {
                        renderedContent
                            .padding(.horizontal, 8)
                            .contentShape(.rect)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
                    }

                    mentionsSection
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
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
                refreshMentions()
            }
        }
        .onDisappear {
            save()
        }
    }

    private var header: some View {
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

            Button {
                if isEditing {
                    exitEditing()
                } else {
                    startEditing()
                }
            } label: {
                Image(systemName: isEditing ? "checkmark.circle.fill" : "square.and.pencil")
                    .foregroundStyle(isEditing ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(isEditing ? "Done (⎋ or ⌘S)" : "Edit this page")

            Button("Close") {
                if isEditing {
                    exitEditing()
                } else {
                    save()
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Rendered (front-page style) content

    @ViewBuilder
    private var renderedContent: some View {
        let blocks = BlockTree.parse(text)
        if blocks.isEmpty {
            Text("Empty page — double-click to write.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(blocks) { block in
                    BlockRowView(block: block, file: renderFile, store: appModel.store ?? dummyStore, onToggle: toggleOnPage)
                }
            }
        }
    }

    private var renderFile: VaultFile {
        VaultFile(url: pageURL ?? URL(fileURLWithPath: "/dev/null"), date: Date(), text: text)
    }

    private var dummyStore: VaultStore {
        VaultStore(vaultURL: URL(fileURLWithPath: "/dev/null"), watchEnabled: false)
    }

    /// Toggles a task inside this page and refreshes the local text (page
    /// writes bypass the days array, so the store can't push updates here).
    private func toggleOnPage(_ block: Block) {
        guard let url = pageURL, let store = appModel.store else { return }
        let file = VaultFile(url: url, date: Date(), text: text)
        store.toggleTodo(in: file, block: block, syncAcrossNotes: settings.syncTodosAcrossNotes)
        text = store.pageText(at: url)
        isDirty = false
        refreshMentions()
    }

    // MARK: - Editing

    private func startEditing() {
        save()
        isEditing = true
    }

    private func exitEditing() {
        save()
        isEditing = false
    }

    /// ⌘S: normalize (drop empty bullets, space wikilink groups), save, and
    /// return to the rendered view.
    private func saveAndQuit() {
        saveTask?.cancel()
        text = NoteFormatter.normalizedForSave(text, isToday: false, now: Date())
        save()
        isEditing = false
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
                // First line rendered as markdown (the wikilink itself);
                // remaining subtree lines show the block's real content.
                MarkdownText(content: mention.lineText)
                    .font(.system(size: 13))
                let extra = mention.blockLines.filter { $0 != mention.lineText }
                if !extra.isEmpty {
                    Text(extra.joined(separator: "\n"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            // Journal mention: close this sheet and reveal the day once the
            // dismissal has finished (MainView's onDismiss consumes the queue).
            appModel.queueReveal(day: date, createIfMissing: false)
            dismiss()
        } else {
            appModel.openPage = AppModel.PageRef(name: mention.title)
        }
    }

    private func refreshMentions() {
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
            refreshMentions()
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
