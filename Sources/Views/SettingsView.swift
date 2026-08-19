import SwiftUI
import AppKit

/// The app's preferences window (⌘,). Vault location, fonts, task syncing,
/// and vault maintenance (empty-note cleanup).
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings

    @State private var cleanupSummary: VaultStore.CleanupResult?
    @State private var migrationSummary: VaultStore.MigrationResult?
    @State private var confirmMigrate = false

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(
                cleanupSummary: $cleanupSummary,
                confirmMigrate: $confirmMigrate,
                migrationSummary: $migrationSummary
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(AppModel.SettingsTab.general.rawValue)
            FontTab()
                .tabItem { Label("Fonts", systemImage: "textformat") }
                .tag(AppModel.SettingsTab.fonts.rawValue)
            RecurringTab()
                .tabItem { Label("Recurring", systemImage: "repeat") }
                .tag(AppModel.SettingsTab.recurring.rawValue)
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(AppModel.SettingsTab.shortcuts.rawValue)
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(AppModel.SettingsTab.advanced.rawValue)
        }
        .frame(width: 460)
        .onAppear { consumeRequestedTab() }
        .onChange(of: appModel.requestedSettingsTab) { _, _ in consumeRequestedTab() }
        .sheet(item: $cleanupSummary) { result in
            CleanupAlert(result: result)
        }
        .sheet(item: $migrationSummary) { result in
            MigrationAlert(result: result)
        }
    }

    private func consumeRequestedTab() {
        if let requested = appModel.requestedSettingsTab {
            selectedTab = requested.rawValue
            appModel.requestedSettingsTab = nil
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
                Toggle("Carry forward unfinished tasks each day", isOn: $settings.autoCarryForward)
                Text("When a new day starts (app launch or midnight rollover), unfinished tasks from previous days are copied into the new day's note automatically. Never duplicates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Carry unfinished tasks into new date notes", isOn: $settings.carryForwardOnNewDate)
                Text("Creating a note for another date — from the calendar, a deadline, or a [[date link]] — also copies unfinished tasks from earlier days into it.")
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

/// Keyboard shortcut reference (fixed, not configurable) plus the one
/// configurable system-wide quick-add shortcut.
private struct ShortcutsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var recording = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Global Quick Add") {
                Toggle("Enable system-wide shortcut", isOn: $settings.globalQuickAddEnabled)
                    .onChange(of: settings.globalQuickAddEnabled) { _, _ in
                        MenuBarController.shared.refreshHotkey()
                    }
                HStack {
                    Text(currentDisplay)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 90, alignment: .leading)
                    Button(recording ? "Press keys… (Esc cancels)" : "Record…") {
                        recording = true
                    }
                    .disabled(!settings.globalQuickAddEnabled)
                    if settings.quickAddHotkey != nil {
                        Button("Reset") {
                            settings.globalQuickAddSpec = AppSettings.HotkeySpec.defaultQuickAdd.storage
                            MenuBarController.shared.refreshHotkey()
                        }
                        .disabled(recording)
                    }
                }
                if recording {
                    HotkeyRecorder(
                        onRecord: { spec in
                            settings.globalQuickAddSpec = spec.storage
                            MenuBarController.shared.refreshHotkey()
                            recording = false
                        },
                        onCancel: { recording = false }
                    )
                    .frame(height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    )
                }
                Text("From any app: opens the DayStream menu bar panel with the caret on the task field. Shortcuts must include ⌘, ⌥ or ⌃.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("In DayStream") {
                shortcutRow("⌘N", "New todo today (opens the editor, caret ready)")
                shortcutRow("⌘F", "Open search and put the cursor in the search bar")
                shortcutRow("⎋", "Close search (when open) or the editor")
                shortcutRow("⌘,", "Open settings")
            }

            Section("In the editor") {
                shortcutRow("⌘S", "Save, auto-format and close")
                shortcutRow("⎋", "Save, auto-format and close")
                shortcutRow("⌘⏎", "Toggle TODO / DONE on the current line")
                shortcutRow("⌘K", "Link selection (clipboard URL → link, else [[wikilink]])")
                shortcutRow("⌘B / ⌘I", "Bold / italic")
                shortcutRow("⇥ / ⇧⇥", "Indent / outdent (or accept [[ autocomplete)")
                shortcutRow("↑ / ↓", "Pick a page-name suggestion")
                shortcutRow("/todo · /doing · /later · /now · /done", "Expand to task markers")
            }

            Section {
                Text("The shortcuts above are fixed — only the global quick-add shortcut is configurable.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    private var currentDisplay: String {
        if !settings.globalQuickAddEnabled { return "Off" }
        return settings.quickAddHotkey?.display ?? "None"
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 190, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(action)
                .font(.system(size: 12.5))
        }
    }
}

/// Captures the next key combination with ⌘/⌥/⌃ into a HotkeySpec. Click
/// to arm (first responder), press a combo to record, Esc to cancel.
private struct HotkeyRecorder: NSViewRepresentable {
    var onRecord: (AppSettings.HotkeySpec) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onRecord: ((AppSettings.HotkeySpec) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // escape
                onCancel?()
                return
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // A bare letter would fire while typing everywhere — require a
            // real modifier (⌘/⌥/⌃; ⇧ alone is not enough).
            guard mods.contains(.command) || mods.contains(.option) || mods.contains(.control) else {
                NSSound.beep()
                return
            }
            let carbon = GlobalHotkeyManager.carbonModifiers(from: mods)
            let display = GlobalHotkeyManager.displayString(keyCode: UInt32(event.keyCode),
                                                             carbonModifiers: carbon)
            onRecord?(AppSettings.HotkeySpec(carbonModifiers: carbon,
                                             keyCode: UInt32(event.keyCode),
                                             display: display))
        }
    }
}

/// Git-backed vault backup: enable toggle, detect or pick the repository
/// folder (which may be a parent of the vault), then commit everything and
/// push via the git CLI. When enabled, a Back Up button also appears in the
/// sidebar; both share the same run state.
private struct AdvancedTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings

    private var repoURL: URL? {
        let path = settings.gitBackupPath
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private var repoIsValid: Bool {
        repoURL.map { GitBackup.isGitRepo($0) } ?? false
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Git Backup") {
                Toggle("Enable git backup", isOn: $settings.gitBackupEnabled)
                Text("When enabled, a Back Up Vault button appears in the sidebar for one-click backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !GitBackup.gitAvailable {
                    Label("git is not installed on this Mac — backup is unavailable.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let url = repoURL {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } else {
                            Text("No repository selected").foregroundStyle(.secondary)
                        }
                        if let url = repoURL {
                            Label(repoIsValid ? "git repository" : "not a git repository",
                                  systemImage: repoIsValid ? "checkmark.circle" : "xmark.circle")
                                .font(.caption2)
                                .foregroundStyle(repoIsValid ? .green : .secondary)
                                .help("Looking for .git in \(url.path)")
                        }
                    }
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                    if let detected = detectedRepo, detected.path != settings.gitBackupPath {
                        Button("Use \(detected.lastPathComponent)") {
                            settings.gitBackupPath = detected.path
                        }
                    }
                }
                .disabled(!settings.gitBackupEnabled)

                Button {
                    appModel.runGitBackup()
                } label: {
                    if appModel.isGitBackingUp {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Backing Up…")
                        }
                    } else {
                        Text("Back Up Now")
                    }
                }
                .disabled(!settings.gitBackupEnabled || !GitBackup.gitAvailable || !repoIsValid || appModel.isGitBackingUp)

                Toggle("Back up automatically", isOn: $settings.autoBackupEnabled)
                    .disabled(!settings.gitBackupEnabled || !GitBackup.gitAvailable || !repoIsValid)

                Picker("Interval", selection: $settings.autoBackupInterval) {
                    ForEach(AppSettings.AutoBackupInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.gitBackupEnabled || !settings.autoBackupEnabled || !GitBackup.gitAvailable || !repoIsValid)

                Text("When enabled, the vault is backed up automatically in the background — weekly is the default. Automatic backup is off unless you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let last = settings.lastAutoBackup {
                    Text("Last successful backup: \(Self.lastBackupFormatter.string(from: last))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("Runs git add -A, commits with the message “\(GitBackup.commitMessage)”, and pushes to the repository's remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Welcome") {
                Button("Show Welcome Tour on Next Launch") {
                    settings.hasSeenWelcome = false
                }
                Text("Replays the one-page intro the next time DayStream opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Warnings") {
                Text("• Everything under the repository folder is committed — if the repo is a parent folder, unrelated files in it are included too.\n• Push goes to the remote's configured branch; your credentials (SSH key or HTTPS credential helper) must already be set up — DayStream will not prompt for passwords.\n• Requires git to be installed (it ships with the Xcode Command Line Tools).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 470)
        .onAppear { autoDetectRepo() }
        .alert(
            appModel.gitBackupResult?.success == true ? "Backup Finished" : "Backup Failed",
            isPresented: Binding(
                get: { appModel.gitBackupResult != nil },
                set: { if !$0 { appModel.gitBackupResult = nil } }
            )
        ) {
            Button("OK") { appModel.gitBackupResult = nil }
        } message: {
            Text(appModel.gitBackupResult?.message ?? "")
        }
    }

    /// First repo at/above the vault (vault itself, or a parent folder).
    private var detectedRepo: URL? {
        appModel.store.map { GitBackup.containingRepo(for: $0.vaultRootURL) } ?? nil
    }

    private static let lastBackupFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func autoDetectRepo() {
        guard settings.gitBackupEnabled, settings.gitBackupPath.isEmpty, let repo = detectedRepo else { return }
        settings.gitBackupPath = repo.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the git repository folder (it may be the parent of your vault)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.gitBackupPath = url.path
    }
}
