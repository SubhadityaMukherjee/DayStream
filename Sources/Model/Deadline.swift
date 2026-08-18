import Foundation
import Observation

/// A dated deadline tracked in the sidebar until deleted. On its due date the
/// title is injected into that day's note as a TODO (duplicate-checked), the
/// same mechanism recurring tasks use.
struct Deadline: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    /// Local start-of-day of the deadline.
    var date: Date

    init(id: UUID = UUID(), title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }

    func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(calendar.startOfDay(for: day), inSameDayAs: date)
    }

    /// Whole days from `day` until the deadline (negative = overdue).
    func daysRemaining(from day: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: day)
        let days = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        return days
    }

    /// Short relative label for the sidebar: "Overdue 2d", "Today", "Tomorrow", "Fri", "Aug 30".
    func label(from day: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysRemaining(from: day, calendar: calendar)
        if days < 0 { return "Overdue \(-days)d" }
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days <= 6 {
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "EEE"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

/// UserDefaults-backed list of deadlines (JSON-encoded array), newest-last.
@Observable
final class DeadlineStore {
    private static let key = "daystream.deadlines"
    private let defaults: UserDefaults

    private(set) var deadlines: [Deadline] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Deadline].self, from: data) {
            deadlines = decoded
        }
    }

    /// Sorted for display: by date, then title.
    var sorted: [Deadline] {
        deadlines.sorted {
            $0.date == $1.date
                ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                : $0.date < $1.date
        }
    }

    func add(_ deadline: Deadline) {
        deadlines.append(deadline)
        persist()
    }

    func delete(_ id: UUID) {
        deadlines.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(deadlines) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
