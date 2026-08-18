import SwiftUI
import Observation

@Observable
final class AppModel {
    static let vaultPathKey = "daystream.vaultPath"

    var store: VaultStore?
    var loadedDays: Int = 60
    var editingDay: Date?
    var scrollToDay: Date?
    var openPage: PageRef?
    var carrySummary: CarryResult?
    var carryButtonPulse = false

    let recurring = RecurringTaskStore()
    let deadlines = DeadlineStore()

    enum SettingsTab: Int {
        case general = 0, fonts = 1, recurring = 2, advanced = 3
    }

    /// Set alongside `openSettings()` to land on a specific tab; SettingsView
    /// consumes (and clears) it on appear/change.
    var requestedSettingsTab: SettingsTab?

    /// A day to reveal once the currently presented sheet has finished
    /// dismissing. Scrolling during the dismissal animation gets swallowed,
    /// so PageView/date links queue here and MainView's sheet `onDismiss`
    /// consumes it.
    struct PendingReveal: Equatable {
        var day: Date
        var createIfMissing: Bool
    }

    var pendingReveal: PendingReveal?

    func queueReveal(day: Date, createIfMissing: Bool) {
        pendingReveal = PendingReveal(day: day, createIfMissing: createIfMissing)
    }

    /// Runs the queued reveal (if any) — call from a sheet's onDismiss.
    func consumePendingReveal() {
        guard let pending = pendingReveal else { return }
        pendingReveal = nil
        if pending.createIfMissing {
            createDayNote(for: pending.day)
        } else {
            reveal(day: pending.day)
        }
    }

    struct PageRef: Identifiable {
        let name: String
        var id: String { name }
    }

    var isConfigured: Bool { store != nil }

    private var lastAppliedDay: Date?
    private var dayTickTimer: Timer?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.vaultPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                setupVault(at: url)
            }
        }
        startDayTimer()
    }

    func setupVault(at url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.vaultPathKey)
        let store = VaultStore(vaultURL: url)
        store.reload()
        self.store = store
        loadedDays = 60
        editingDay = nil
        lastAppliedDay = nil
        // Deadlines live in defaults + a markdown mirror inside the vault;
        // pick up hand-edited entries from the file before seeding today.
        deadlines.vaultFileURL = store.deadlinesFileURL
        deadlines.syncWithVaultFile()
        ensureTodayExists()
        applyScheduledForToday()
    }

    func disconnectVault() {
        UserDefaults.standard.removeObject(forKey: Self.vaultPathKey)
        store = nil
    }

    func ensureTodayExists() {
        store?.ensureTodayFile()
        if let store, !store.days.contains(where: { $0.date == JournalDate.startOfDay(Date()) }) {
            store.reload()
        }
    }

    func goToToday() {
        ensureTodayExists()
        applyScheduledForToday()
        let today = JournalDate.startOfDay(Date())
        reveal(day: today)
    }

    /// Creates the journal file for a past/future date if missing, seeds any
    /// recurring tasks and deadlines due that day, then reveals it.
    func createDayNote(for date: Date) {
        guard let store else { return }
        store.ensureDayFile(for: date)
        store.applyRecurringTasks(recurring.tasks, to: date)
        store.applyDeadlines(deadlines.deadlines, to: date)
        if !store.days.contains(where: { $0.date == date }) {
            store.reload()
        }
        reveal(day: date)
    }

    func reveal(day: Date) {
        // Make sure the target day is within the loaded window.
        if let store,
           let idx = store.days.firstIndex(where: { $0.date == day }),
           idx + 10 > loadedDays {
            loadedDays = min(idx + 30, store.days.count)
        }
        scrollToDay = day
    }

    func moreDaysAvailable() -> Bool {
        guard let store else { return false }
        return loadedDays < store.days.count
    }

    func loadMoreDays() {
        guard moreDaysAvailable() else { return }
        loadedDays = min(loadedDays + 60, store?.days.count ?? loadedDays)
    }

    func runCarryForward() {
        guard let store else { return }
        let result = store.carryForward()
        carrySummary = result
        ensureTodayExists()
    }

    // MARK: - Scheduled work (recurring + deadlines + auto carry-forward)

    private func applyScheduledForToday() {
        guard let store else { return }
        let today = JournalDate.startOfDay(Date())
        // First application of the day this session (launch after midnight or
        // rollover while open): also carry unfinished tasks forward, silently.
        let isFirstToday = lastAppliedDay != today
        store.applyRecurringTasks(recurring.tasks, to: Date())
        store.applyDeadlines(deadlines.deadlines, to: Date())
        if isFirstToday, AppSettings.shared.autoCarryForward {
            _ = store.carryForward()
        }
        ensureTodayExists()
        lastAppliedDay = today
    }

    /// Catches midnight rollover while the app is open: reloads the vault and
    /// seeds the new day's note (today's file + recurring tasks + deadlines).
    private func startDayTimer() {
        dayTickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let today = JournalDate.startOfDay(Date())
            guard today != self.lastAppliedDay else { return }
            self.store?.reload()
            self.applyScheduledForToday()
        }
    }
}
