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
    var showNewNote = false
    var carrySummary: CarryResult?
    var carryButtonPulse = false

    struct PageRef: Identifiable {
        let name: String
        var id: String { name }
    }

    var isConfigured: Bool { store != nil }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.vaultPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                setupVault(at: url)
            }
        }
    }

    func setupVault(at url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.vaultPathKey)
        let store = VaultStore(vaultURL: url)
        store.reload()
        self.store = store
        loadedDays = 60
        editingDay = nil
        ensureTodayExists()
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
        let today = JournalDate.startOfDay(Date())
        reveal(day: today)
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
}
