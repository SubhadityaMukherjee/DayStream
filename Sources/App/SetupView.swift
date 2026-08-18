import SwiftUI
import AppKit

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedURL: URL?
    @State private var validation: Validation?
    @State private var errorMessage: String?

    enum Validation {
        case rootVault(journals: Int, pages: Int)
        case journalsDirectory(files: Int)

        var summary: String {
            switch self {
            case .rootVault(let journals, let pages):
                return "Vault detected: \(journals) journal files, \(pages) pages."
            case .journalsDirectory(let files):
                return "Journals folder detected: \(files) daily-note files."
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.pencil.on.square")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("DayStream")
                .font(.largeTitle.bold())
            Text("A daily-notes stream for your markdown vault.")
                .foregroundStyle(.secondary)
            Text("Pick the folder that contains your `journals` directory\n(Logseq vault root), or the journals folder itself.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Choose Vault Folder…") { chooseFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            if let validation {
                Label(validation.summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.horizontal)
                Text(selectedURL?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Use This Vault") {
                    if let url = selectedURL {
                        appModel.setupVault(at: url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your markdown vault (the folder containing journals/)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        validate(url)
    }

    private func validate(_ url: URL) {
        let fm = FileManager.default
        let journalsSub = url.appendingPathComponent("journals", isDirectory: true)

        if fm.fileExists(atPath: journalsSub.path) {
            let journals = countJournalFiles(in: journalsSub)
            let pages = ((try? fm.contentsOfDirectory(
                atPath: url.appendingPathComponent("pages", isDirectory: true).path)) ?? [])
                .filter { $0.hasSuffix(".md") }
                .count
            if journals > 0 {
                selectedURL = url
                validation = .rootVault(journals: journals, pages: pages)
                errorMessage = nil
                return
            }
            errorMessage = "The journals folder in “\(url.lastPathComponent)” is empty."
            validation = nil
            return
        }

        // Maybe they picked the journals folder itself.
        let files = countJournalFiles(in: url)
        if files >= 3 {
            selectedURL = url
            validation = .journalsDirectory(files: files)
            errorMessage = nil
        } else {
            errorMessage = "No journals found. Pick a folder that contains a “journals” directory with daily notes."
            validation = nil
        }
    }

    private func countJournalFiles(in dir: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter(JournalDate.isJournalFilename).count
    }
}
