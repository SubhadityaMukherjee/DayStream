import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var appModel = appModel
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 260)
                .background(.bar)

            Divider()

            if let store = appModel.store {
                VStack(spacing: 0) {
                    SearchBarView()
                    Divider()
                    DailyStreamView(store: store)
                        .id(store.vaultURL)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .environment(
            \.openURL,
            OpenURLAction { url in
                if handleInternalURL(url) {
                    return .handled
                }
                return .systemAction
            }
        )
        .sheet(item: $appModel.openPage, onDismiss: {
            appModel.consumePendingReveal()
        }) { page in
            PageView(pageName: page.name)
                .id(page.name)
                .frame(minWidth: 560, minHeight: 460)
        }
        .alert(
            "Carry Forward",
            isPresented: Binding(
                get: { appModel.carrySummary != nil },
                set: { if !$0 { appModel.carrySummary = nil } }
            )
        ) {
            Button("OK") { appModel.carrySummary = nil }
        } message: {
            Text(appModel.carrySummary?.summary ?? "")
        }
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
        .onAppear {
            appModel.goToToday()
        }
    }

    private func handleInternalURL(_ url: URL) -> Bool {
        guard url.scheme == "daystream" else { return false }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        case "page":
            if let name = comps?.queryItems?.first(where: { $0.name == "name" })?.value {
                appModel.openPage = AppModel.PageRef(name: name)
                return true
            }
        case "date":
            if let value = comps?.queryItems?.first(where: { $0.name == "value" })?.value {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd"
                if let date = f.date(from: value) {
                    let target = JournalDate.startOfDay(date)
                    // If a page sheet is open, close it and reveal once the
                    // dismissal completes; otherwise reveal right away.
                    if appModel.openPage != nil {
                        appModel.queueReveal(day: target, createIfMissing: true)
                        appModel.openPage = nil
                    } else {
                        appModel.createDayNote(for: target)
                    }
                    return true
                }
            }
        default:
            break
        }
        return false
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @State private var showNewDeadline = false

    var body: some View {
        VStack(spacing: 16) {
            CalendarView()
                .padding(.horizontal, 12)

            Divider()

            VStack(spacing: 10) {
                Button {
                    appModel.goToToday()
                } label: {
                    Label("Today", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    appModel.runCarryForward()
                } label: {
                    Label("Carry Forward Unfinished", systemImage: "arrow.down.forward.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    showNewDeadline = true
                } label: {
                    Label("Deadline…", systemImage: "flag")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    openRecurringSettings()
                } label: {
                    Label("Recurring Tasks…", systemImage: "repeat")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                if appModel.canGitBackupFromSidebar {
                    Button {
                        appModel.runGitBackup()
                    } label: {
                        HStack(spacing: 6) {
                            if appModel.isGitBackingUp {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label(appModel.isGitBackingUp ? "Backing Up…" : "Back Up Vault",
                                  systemImage: appModel.isGitBackingUp ? "arrow.triangle.2.circlepath" : "arrow.up.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(appModel.isGitBackingUp)
                    .help("Commit the vault and push to its git remote")
                }
            }
            .padding(.horizontal, 12)

            deadlineSection

            if let store = appModel.store {
                Spacer()
                HStack {
                    Text("\(store.days.count) daily notes · \(store.pageCount) pages")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
                }
                .padding(.bottom, 10)
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 16)
        .sheet(isPresented: $showNewDeadline) {
            NewDeadlineSheet()
                .frame(minWidth: 380, minHeight: 240)
        }
    }

    private func openRecurringSettings() {
        appModel.requestedSettingsTab = .recurring
        openSettings()
    }

    /// Persistent deadline list, soonest first. Click jumps to that day's
    /// note; overdue items are red until removed.
    @ViewBuilder
    private var deadlineSection: some View {
        let items = appModel.deadlines.sorted
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Deadlines", systemImage: "flag.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(items.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { deadline in
                            DeadlineRow(deadline: deadline) {
                                appModel.deadlines.delete(deadline.id)
                            } onOpen: {
                                appModel.createDayNote(for: deadline.date)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct DeadlineRow: View {
    let deadline: Deadline
    let onDelete: () -> Void
    let onOpen: () -> Void

    private var days: Int { deadline.daysRemaining() }

    private var labelColor: Color {
        if days < 0 { return .red }
        if days == 0 { return .orange }
        if days <= 2 { return .accentColor }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: days < 0 ? "flag.fill" : "flag")
                .font(.system(size: 10))
                .foregroundStyle(labelColor)
            Button(action: onOpen) {
                HStack {
                    Text(deadline.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(deadline.label())
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(labelColor)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(deadline.title) — jump to the deadline's day")
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove deadline")
        }
        .padding(.vertical, 1)
    }
}

/// Sheet behind the "Deadline…" button: title + date, added to the sidebar list.
private struct NewDeadlineSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = JournalDate.startOfDay(Date())

    var body: some View {
        VStack(spacing: 14) {
            Text("New Deadline")
                .font(.system(size: 14, weight: .semibold))
            TextField("What is due? (e.g. Paper submission)", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.field)
            Text("Shows in the sidebar until removed; the task appears on that day's note.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Add Deadline", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func add() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appModel.deadlines.add(Deadline(title: trimmed, date: JournalDate.startOfDay(date)))
        // Seed the note immediately when the deadline is for today.
        if JournalDate.startOfDay(date) == JournalDate.startOfDay(Date()) {
            appModel.store?.applyDeadlines(appModel.deadlines.deadlines, to: date)
        }
        dismiss()
    }
}

/// Search field above the stream with a dropdown of matches across every
/// journal and page. Journals jump to their day; pages open in a sheet.
struct SearchBarView: View {
    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var hits: [VaultStore.SearchHit] = []
    @FocusState private var focused: Bool

    private var isExpanded: Bool {
        focused && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        field
            .overlay(alignment: .topLeading) {
                if isExpanded {
                    panel
                        .offset(y: 36)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .zIndex(10)
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search all notes and pages…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { openFirstHit() }
            if !query.isEmpty {
                Button {
                    query = ""
                    hits = []
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary.opacity(0.4))
        )
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hits = appModel.store?.search(trimmed, limit: 20) ?? []
        }
    }

    /// Content-sized dropdown: top matches only, with a "more" footer instead
    /// of an inner scroll view (scroll views are greedy and break sizing).
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                Text("No matches")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(hits.prefix(8)) { hit in
                    row(hit)
                }
                if hits.count > 8 {
                    Text("\(hits.count - 8) more — press ⏎ for the top match")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func row(_ hit: VaultStore.SearchHit) -> some View {
        Button {
            open(hit)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.isPage ? "Page · \(hit.title)" : Self.dayFormatter.string(from: hit.date!))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if hit.lineText != "Page" {
                    Text(hit.lineText)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func openFirstHit() {
        if let first = hits.first {
            open(first)
        }
    }

    private func open(_ hit: VaultStore.SearchHit) {
        query = ""
        hits = []
        focused = false
        if let date = hit.date {
            appModel.reveal(day: date)
        } else {
            appModel.openPage = AppModel.PageRef(name: hit.title)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
