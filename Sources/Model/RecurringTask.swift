import Foundation
import Observation

/// A task that reappears in the day's note on a schedule: every day, on a
/// given weekday, or once on a given date. Injection is duplicate-checked
/// against the note's existing content, so applying twice never doubles up.
struct RecurringTask: Identifiable, Equatable {
    enum Schedule: Equatable, Codable {
        case daily
        /// 1 = Sunday … 7 = Saturday (Calendar weekday numbering).
        case weekly(weekday: Int)
        /// Every other week on the given weekday. Weeks alternate from a
        /// fixed epoch so the on/off parity is stable across years,
        /// relaunches and devices.
        case biweekly(weekday: Int)
        case once(date: Date)
    }

    var id: UUID
    var title: String
    var schedule: Schedule
    /// Wikilink name of the section this task groups under in the day's
    /// note, overriding the global default when set.
    var header: String?
    /// The day the task was added: it never fires before this, and a
    /// biweekly task alternates weeks counting from it.
    var startDate: Date

    /// Legacy persisted tasks predate `startDate`; anchoring them at the
    /// epoch keeps their historical due pattern (and always allows due
    /// dates) instead of breaking them.
    private static let legacyStartDate = Date(timeIntervalSince1970: 0)

    init(id: UUID = UUID(), title: String, schedule: Schedule,
         header: String? = nil, startDate: Date = JournalDate.startOfDay(Date())) {
        self.id = id
        self.title = title
        self.schedule = schedule
        self.header = header
        self.startDate = startDate
    }

    /// Manual Codable: `header` and `startDate` were added after tasks were
    /// already persisted, and synthesized decoding rejects JSON that lacks
    /// the keys.
    enum CodingKeys: String, CodingKey {
        case id, title, schedule, header, startDate
    }

    /// Start of the week containing `day`, by arithmetic — locale-backed
    /// week APIs (dateInterval(of:.weekOfYear)) can stall for seconds per
    /// call on some systems.
    private static func weekStart(of day: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: day)
        let back = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    /// Whole weeks between the week starts of two days. Rounded day
    /// difference: DST makes local-midnight gaps 23/25h.
    private static func weeksBetween(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        Int((weekStart(of: b, calendar: calendar).timeIntervalSince(
            weekStart(of: a, calendar: calendar)) / 86400).rounded()) / 7
    }

    func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        let start = calendar.startOfDay(for: startDate)
        guard d >= start else { return false }
        switch schedule {
        case .daily:
            return true
        case .weekly(let weekday):
            return calendar.component(.weekday, from: d) == weekday
        case .biweekly(let weekday):
            guard calendar.component(.weekday, from: d) == weekday else { return false }
            return Self.weeksBetween(start, d, calendar: calendar) % 2 == 0
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
        case .biweekly(let weekday):
            let idx = (weekday - 1 + 7) % 7
            return "Bi-weekly on \(calendar.weekdaySymbols[idx])"
        case .once(let date):
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return "On \(f.string(from: date))"
        }
    }
}

extension RecurringTask: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        schedule = try c.decode(Schedule.self, forKey: .schedule)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? Self.legacyStartDate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(schedule, forKey: .schedule)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encode(startDate, forKey: .startDate)
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
