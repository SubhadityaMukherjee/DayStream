import Foundation
import Observation

/// A task that reappears in the day's note on a schedule: every day, on a
/// given weekday, or once on a given date. Injection is duplicate-checked
/// against the note's existing content, so applying twice never doubles up.
struct RecurringTask: Identifiable, Codable, Equatable {
    enum Schedule: Codable, Equatable {
        case daily
        /// 1 = Sunday … 7 = Saturday (Calendar weekday numbering).
        case weekly(weekday: Int)
        case once(date: Date)
    }

    var id: UUID
    var title: String
    var schedule: Schedule

    init(id: UUID = UUID(), title: String, schedule: Schedule) {
        self.id = id
        self.title = title
        self.schedule = schedule
    }

    func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        switch schedule {
        case .daily:
            return true
        case .weekly(let weekday):
            return calendar.component(.weekday, from: d) == weekday
        case .once(let date):
            return calendar.isDate(d, inSameDayAs: date)
        }
    }

    func scheduleDescription(calendar: Calendar = .current) -> String {
        switch schedule {
        case .daily:
            return "Daily"
        case .weekly(let weekday):
            let idx = (weekday - 1 + 7) % 7
            return "Weekly on \(calendar.weekdaySymbols[idx])"
        case .once(let date):
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return "On \(f.string(from: date))"
        }
    }
}

/// UserDefaults-backed list of recurring tasks (JSON-encoded array).
@Observable
final class RecurringTaskStore {
    private static let key = "daystream.recurringTasks"
    private let defaults: UserDefaults

    private(set) var tasks: [RecurringTask] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([RecurringTask].self, from: data) {
            tasks = decoded
        }
    }

    func add(_ task: RecurringTask) {
        tasks.append(task)
        persist()
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
