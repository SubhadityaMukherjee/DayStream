import SwiftUI

/// The app's preferences window (⌘,). Vault location, fonts, task syncing,
/// and vault maintenance (empty-note cleanup).
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings

    @State private var cleanupSummary: VaultStore.CleanupResult?
    @State private var migrationSummary: VaultStore.MigrationResult?
    @State private var confirmMigrate = false

    var body: some View {
        TabView {
            GeneralTab(
                cleanupSummary: $cleanupSummary,
                confirmMigrate: $confirmMigrate,
                migrationSummary: $migrationSummary
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            FontTab()
                .tabItem { Label("Fonts", systemImage: "textformat") }
            RecurringTab()
                .tabItem { Label("Recurring", systemImage: "repeat") }
        }
        .frame(width: 460)
        .sheet(item: $cleanupSummary) { result in
            CleanupAlert(result: result)
        }
        .sheet(item: $migrationSummary) { result in
            MigrationAlert(result: result)
        }
    }
}

extension VaultStore.CleanupResult: Identifiable {
    public var id: String { "cleanup-\(deletedJournals)-\(deletedPages)" }
}

extension VaultStore.MigrationResult: Identifiable {
    public var id: String { "migration-\(backedUp)-\(migrated)-\(conflicts)" }
}

private struct MigrationAlert: View {
    let result: VaultStore.MigrationResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Filename Migration")
                .font(.headline)
            Text(result.summary)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
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
    @Binding var confirmMigrate: Bool
    @Binding var migrationSummary: VaultStore.MigrationResult?

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
                Button("Migrate legacy filenames…") {
                    confirmMigrate = true
                }
                Text("Renames journal files like 2026_08_18.md or 18-08-2026.md to the 2026-08-18.md convention. Originals are copied to backup/ first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Legacy formats in this vault: \(legacyCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 430)
        .confirmationDialog(
            "Migrate legacy filenames?",
            isPresented: $confirmMigrate,
            titleVisibility: .visible
        ) {
            Button("Migrate") { migrationSummary = appModel.store?.migrateLegacyFilenames() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every original is copied to backup/ before renaming. Files whose target name already exists with different content are skipped.")
        }
    }

    private var legacyCount: Int {
        guard let store = appModel.store else { return 0 }
        return store.days.reduce(0) { count, day in
            count + day.files.filter {
                let stem = ($0.url.lastPathComponent as NSString).deletingPathExtension
                return !(stem =~~ "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
            }.count
        }
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

/// Manage recurring tasks: daily, weekly on a weekday, or once on a date.
/// Due tasks are seeded at the top of the day's note (duplicate-checked).
private struct RecurringTab: View {
    @Environment(AppModel.self) private var appModel

    @State private var title = ""
    @State private var mode = 0 // 0 daily, 1 weekly, 2 once
    @State private var weekday = 2
    @State private var onceDate = JournalDate.startOfDay(Date())

    var body: some View {
        Form {
            Section("Existing") {
                if appModel.recurring.tasks.isEmpty {
                    Text("No recurring tasks yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.recurring.tasks) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title)
                                    .lineLimit(1)
                                Text(task.scheduleDescription())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                appModel.recurring.delete(task.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            Section("Add") {
                TextField("Task (e.g. Review notes)", text: $title)
                    .onSubmit(add)

                Picker("Repeats", selection: $mode) {
                    Text("Daily").tag(0)
                    Text("Weekly").tag(1)
                    Text("Once").tag(2)
                }
                .pickerStyle(.segmented)

                if mode == 1 {
                    Picker("On", selection: $weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                if mode == 2 {
                    DatePicker("Date", selection: $onceDate, displayedComponents: .date)
                        .datePickerStyle(.field)
                }

                Button("Add Recurring Task", action: add)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Due tasks appear as a TODO at the top of that day's note, and are never duplicated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
    }

    private func add() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let schedule: RecurringTask.Schedule
        switch mode {
        case 1: schedule = .weekly(weekday: weekday)
        case 2: schedule = .once(date: onceDate)
        default: schedule = .daily
        }
        appModel.recurring.add(RecurringTask(title: trimmed, schedule: schedule))
        title = ""
    }
}
