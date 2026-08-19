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

    /// Short relative label for the sidebar, always including the days left:
    /// "Overdue 2d", "Today", "Tomorrow", "Fri · 3d", "Sep 30 · 43d".
    func label(from day: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysRemaining(from: day, calendar: calendar)
        if days < 0 { return "Overdue \(-days)d" }
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        let dateText = days <= 6
            ? Self.weekdayFormatter.string(from: date)
            : Self.shortDateFormatter.string(from: date)
        return "\(dateText) · \(days)d"
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}

/// UserDefaults-backed list of deadlines (JSON-encoded array), mirrored to
/// `<vault root>/deadlines.md` so the data also lives in the vault itself.
/// The file is human-editable: entries not known to the app are merged in
/// when the vault is connected.
@Observable
final class DeadlineStore {
    private static let key = "daystream.deadlines"
    private let defaults: UserDefaults

    private(set) var deadlines: [Deadline] = []

    /// Markdown mirror target; nil until a vault is connected.
    var vaultFileURL: URL?

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
        writeVaultFile()
    }

    // MARK: - Vault markdown mirror

    private static func fileDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Rewrites the mirror file from the in-memory list. Format:
    /// `- [yyyy-MM-dd] Title`.
    func writeVaultFile() {
        guard let url = vaultFileURL else { return }
        let df = Self.fileDateFormatter()
        let text = sorted
            .map { "- [\(df.string(from: $0.date))] \($0.title)" }
            .joined(separator: "\n")
        try? (text.isEmpty ? "" : text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Merges hand-edited entries from the mirror file into the list, then
    /// normalizes the file. Called when a vault is connected.
    func syncWithVaultFile() {
        guard let url = vaultFileURL else { return }
        let df = Self.fileDateFormatter()
        var added = false
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let known = Set(deadlines.map { "\($0.title.lowercased())|\(df.string(from: $0.date))" })
            for line in text.components(separatedBy: "\n") {
                guard let g = Self.captures(line, #"^-\s*\[(\d{4}-\d{2}-\d{2})\]\s*(.+)$"#) else { continue }
                guard let date = df.date(from: g[0]) else { continue }
                let title = g[1].trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                let key = "\(title.lowercased())|\(g[0])"
                if !known.contains(key) {
                    deadlines.append(Deadline(title: title, date: JournalDate.startOfDay(date)))
                    added = true
                }
            }
        }
        if added {
            persist()
        } else {
            writeVaultFile()
        }
    }

    private static func captures(_ s: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1
        else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }
}
