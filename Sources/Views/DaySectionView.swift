import SwiftUI

/// One day in the stream: sticky header + rendered blocks, or the raw
/// markdown editor when editing. Saves are debounced.
struct DaySectionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    let day: JournalDay
    let store: VaultStore

    @State private var isEditing = false
    @State private var draft = ""
    /// File text as of the last sync (start of editing, our own save, or an
    /// external update). Used to detect external changes while editing.
    @State private var base = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmDelete = false
    /// Incremented by addTodo; lands the caret after the appended "- TODO ".
    @State private var caretAtEndRequest = 0

    private var isToday: Bool {
        day.date == JournalDate.startOfDay(Date())
    }

    private var editFile: VaultFile? {
        day.editFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
        // One container per day so the header card and the badges inside its
        // blocks batch into a single glass render pass — without this each
        // badge pays for its own effect and scrolling stutters.
        .glassContainer(spacing: 0)
        .onDisappear {
            flushSave()
        }
        .onChange(of: appModel.editingDay) { _, newEditingDay in
            if newEditingDay != day.date, isEditing {
                endEditing()
            }
        }
        .onChange(of: day.date) { _, _ in
            // The stream's List recycles rows: if this cell is handed a
            // different day, drop any leftover edit state from the old one
            // (pending saves were already flushed by onDisappear).
            saveTask?.cancel()
            saveTask = nil
            isEditing = false
            draft = ""
            base = ""
        }
        .onChange(of: editFile?.text) { _, newText in
            // External change (carry-forward, another editor, file watcher):
            // adopt it if the user hasn't typed since the last sync, so a
            // stale draft can never overwrite the file on close.
            guard isEditing, let newText else { return }
            if draft == base {
                draft = newText
            }
            base = newText
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.dateFormatter.string(from: day.date))
                    .font(settings.dayHeadingFont)
                Text(Self.weekdayFormatter.string(from: day.date))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if isToday {
                    Text("Today")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .tintedGlassBackground(Color.accentColor.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                if day.files.count > 1 {
                    Text("\(day.files.count) files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("This date exists in multiple filename formats (e.g. 2026_08_14.md and 2026-08-14.md). Editing targets the file with content.")
                }
                Spacer()
                if dayIsEmpty {
                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.roundIcon(.red))
                    .help("Delete this empty note")
                    .confirmationDialog(
                        "Delete the empty note for \(Self.dateFormatter.string(from: day.date))?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Note", role: .destructive) { deleteEmptyDay() }
                    }
                }
            }

            editorControls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassCardBackground(in: RoundedRectangle(cornerRadius: 10))
    }

    private var editorControls: some View {
        HStack(spacing: 4) {
            Button(action: addTodo) {
                Image(systemName: "plus")
            }
            .buttonStyle(.roundIcon)
            .help("Add a task to this day")

            Button {
                if isEditing {
                    endEditing()
                } else {
                    startEditing()
                }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "square.and.pencil")
            }
            .buttonStyle(.roundIcon(isEditing ? .green : .secondary))
            .help(isEditing ? "Done (⎋)" : "Edit this day")
        }
    }

    /// "+" — append a fresh `- TODO ` line and open the editor with the
    /// caret after it, so only the task title needs typing.
    private func addTodo() {
        flushSave()
        let ensured = store.ensureDayFile(for: day.date)
        let baseText = isEditing ? draft : ensured.text
        let separator = baseText.isEmpty || baseText.hasSuffix("\n") ? "" : "\n"
        let newText = baseText + separator + "- TODO "
        draft = newText
        base = newText
        caretAtEndRequest += 1
        if !isEditing {
            isEditing = true
            appModel.editingDay = day.date
        }
        store.write(text: newText, to: ensured.url)
    }

    private var dayIsEmpty: Bool {
        day.files.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func deleteEmptyDay() {
        for file in day.files where file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: file.url)
        }
        store.reload()
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            MarkdownEditorView(
                text: $draft,
                imageImporter: imageImporter,
                pageNamesProvider: { [weak store] in store?.allPageNames() ?? [] },
                onTextChanged: { newText in
                    scheduleSave(newText)
                },
                onCommit: {
                    endEditing()
                },
                onSaveCommit: {
                    saveAndQuit()
                },
                caretAtEndRequest: caretAtEndRequest
            )
            .padding(.horizontal, -6)
            .padding(10)
            .glassCardBackground(in: RoundedRectangle(cornerRadius: 12))
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(day.displayFiles, id: \.url) { file in
                    fileView(file)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            // Simultaneous so single clicks still reach `[[wikilinks]]`.
            .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
        }
    }

    @ViewBuilder
    private func fileView(_ file: VaultFile) -> some View {
        if file.blocks.isEmpty {
            emptyPlaceholder
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(file.blocks) { block in
                    BlockRowView(block: block, file: file, store: store)
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        HStack {
            Text(isToday ? "Nothing here yet — double-click to write, or carry forward unfinished tasks."
                         : "Empty note.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCardBackground(in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if isToday { startEditing() }
        })
    }

    private func startEditing() {
        flushSave()
        guard let file = editFile else { return }
        draft = file.text
        base = file.text
        isEditing = true
        appModel.editingDay = day.date
    }

    /// Dropped images are copied into the vault's assets/ directory and embedded.
    private func imageImporter(_ data: Data, name: String?) -> String? {
        store.importImage(data, originalName: name)
    }

    private func endEditing() {
        flushSave()
        isEditing = false
        if appModel.editingDay == day.date {
            appModel.editingDay = nil
        }
    }

    /// ⌘S: normalize the draft (drop empty bullets, space out top-level
    /// `[[wikilink]]` groups, stamp `added::` on today's new tasks), write it,
    /// and leave edit mode.
    private func saveAndQuit() {
        saveTask?.cancel()
        guard let file = editFile else {
            endEditing()
            return
        }
        let normalized = NoteFormatter.normalizedForSave(draft, isToday: isToday, now: Date())
        draft = normalized
        base = normalized
        store.write(text: normalized, to: file.url)
        isEditing = false
        if appModel.editingDay == day.date {
            appModel.editingDay = nil
        }
    }

    private func scheduleSave(_ text: String) {
        saveTask?.cancel()
        guard let file = editFile else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let url = file.url
            let payload = text
            await MainActor.run {
                store.write(text: payload, to: url)
            }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        // The scheduled task may have been cancelled before firing: save inline if dirty.
        guard isEditing, let file = editFile, draft != file.text else { return }
        store.write(text: draft, to: file.url)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
}
