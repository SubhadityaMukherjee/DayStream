import SwiftUI

/// The app's preferences window (⌘,). Vault location, fonts, task syncing,
/// and vault maintenance (empty-note cleanup).
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings

    @State private var cleanupSummary: VaultStore.CleanupResult?

    var body: some View {
        TabView {
            GeneralTab(cleanupSummary: $cleanupSummary)
                .tabItem { Label("General", systemImage: "gearshape") }
            FontTab()
                .tabItem { Label("Fonts", systemImage: "textformat") }
        }
        .frame(width: 460)
        .sheet(item: $cleanupSummary) { result in
            CleanupAlert(result: result)
        }
    }
}

extension VaultStore.CleanupResult: Identifiable {
    public var id: String { "cleanup-\(deletedJournals)-\(deletedPages)" }
}

private struct CleanupAlert: View {
    let result: VaultStore.CleanupResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Deleted \(result.deletedJournals + result.deletedPages) empty note\(result.deletedJournals + result.deletedPages == 1 ? "" : "s")")
                .font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))
                .foregroundStyle(.secondary)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Binding var cleanupSummary: VaultStore.CleanupResult?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Vault") {
                vaultRow
            }
            Section("Tasks") {
                Toggle("Sync task state across notes", isOn: $settings.syncTodosAcrossNotes)
                Text("Checking a task updates every note that repeats the same task text — journals and pages alike.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Maintenance") {
                Button("Delete empty notes…", action: deleteEmptyNotes)
                Text("Removes journal and page files that contain nothing but whitespace. Notes with content are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
    }

    private var vaultRow: some View {
        HStack {
            if let store = appModel.store {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.vaultURL.lastPathComponent)
                        .lineLimit(1)
                    Text(store.vaultURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                Text("No vault connected").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change…") { appModel.disconnectVault() }
        }
    }

    private func deleteEmptyNotes() {
        cleanupSummary = appModel.store?.deleteEmptyNotes()
    }
}

private struct FontTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Typeface", selection: $settings.fontDesign) {
                Text("System (SF Pro)").tag(0)
                Text("Serif (New York)").tag(1)
                Text("Rounded").tag(2)
                Text("Monospace").tag(3)
            }
            .pickerStyle(.radioGroup)

            HStack {
                Text("Size")
                Slider(value: $settings.fontSize, in: 11...22, step: 0.5)
                Text(String(format: "%.0f pt", settings.fontSize))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The quick brown fox jumps over the lazy dog — 0123456789")
                    .font(settings.streamFont)
                Text("Headings look like this")
                    .font(settings.streamFontSemibold)
            }
            .padding(.vertical, 4)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }
}
