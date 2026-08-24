import SwiftUI

/// Sheet for a `[[wikilink]]` page. The page *is* the editor (live markdown
/// rendering, no edit/view split), with linked references below. ⎋ saves
/// and closes; ⌘S auto-formats and keeps the sheet open.
struct PageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let pageName: String

    @State private var loaded = false
    @State private var pageURL: URL?
    @State private var isDirty = false
    /// Live editor text and the debounced save task. Kept outside @State
    /// invalidation (a class in @State): per-keystroke writes here must not
    /// re-render the sheet on every key press. `text` stays synced at save
    /// boundaries and is what empty-checks and mentions read.
    @State private var session = EditorSession()
    /// External text to push into the live editor (⌘S normalization).
    @State private var pushedText: String?
    @State private var mentions: [VaultStore.Mention] = []
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownEditorView(
                        text: session.text,
                        pushedText: pushedText,
                        imageImporter: imageImporter,
                        pageNamesProvider: { [weak appModel] in appModel?.store?.allPageNames() ?? [] },
                        onTextChanged: { newText in
                            session.text = newText
                            if !isDirty {
                                isDirty = true
                            }
                            scheduleSave()
                        },
                        onCommit: {
                            save()
                            dismiss()
                        },
                        onSaveCommit: {
                            saveAndNormalize()
                        },
                        onOpenLink: { openURL($0) },
                        onTodoToggled: { taskContent, nowDone in
                            guard settings.syncTodosAcrossNotes, let url = pageURL else { return }
                            appModel.store?.syncTodoState(taskContent: taskContent,
                                                           to: nowDone ? .done : .open,
                                                           excluding: url)
                        }
                    )
                    .padding(.horizontal, 8)

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
                session.text = url.map { store.pageText(at: $0) } ?? ""
                session.base = session.text
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

            Button("Close") {
                save()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    /// ⌘S: normalize the draft, write it, and push the normalized text back
    /// into the editor (caret kept).
    private func saveAndNormalize() {
        session.cancelSave()
        let normalized = NoteFormatter.normalizedForSave(session.text, isToday: false, now: Date())
        session.text = normalized
        session.base = normalized
        pushedText = normalized
        save()
    }

    private var pageTextIsEmpty: Bool? {
        guard let pageURL else { return nil }
        return session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            .glassCardBackground(in: RoundedRectangle(cornerRadius: 8))
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

    private func scheduleSave() {
        session.cancelSave()
        session.saveTask = Task {
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
        if current != session.text {
            store.write(text: session.text, to: url)
            isDirty = false
            refreshMentions()
        }
    }

    private func deleteEmptyPage() {
        guard let store = appModel.store, let url = pageURL else { return }
        session.cancelSave()
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
