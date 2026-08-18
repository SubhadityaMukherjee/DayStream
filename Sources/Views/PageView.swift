import SwiftUI

/// Editor sheet for a `[[wikilink]]` page. Creates the page file on first save.
struct PageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let pageName: String

    @State private var text = ""
    @State private var loaded = false
    @State private var pageURL: URL?
    @State private var isDirty = false

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
                Button("Close") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            MarkdownEditorView(text: $text) { newText in
                isDirty = true
                scheduleSave()
            } onCommit: {
                save()
                dismiss()
            }
            .padding(8)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let store = appModel.store {
                let url = store.pageURL(named: pageName, createIfMissing: true)
                pageURL = url
                text = url.map { store.pageText(at: $0) } ?? ""
            }
        }
        .onDisappear {
            save()
        }
    }

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
        }
    }
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
        appModel.showNewNote = false
        appModel.openPage = AppModel.PageRef(name: trimmed)
        dismiss()
    }
}
