import Foundation

/// Parses journal filenames. Supports the three formats found in real Logseq vaults:
/// `yyyy-MM-dd.md` (ISO, used for new files), `yyyy_MM_dd.md` (Logseq default),
/// and `dd-MM-yyyy.md` (custom, day-first). Non-date files are rejected.
enum JournalDate {
    static let newFileFormat = "yyyy-MM-dd"

    static func date(fromFilename filename: String) -> Date? {
        let name = (filename as NSString).deletingPathExtension
        let format: String
        switch true {
        case name =~~ "^[0-9]{4}-[0-9]{2}-[0-9]{2}$": format = "yyyy-MM-dd"
        case name =~~ "^[0-9]{4}_[0-9]{2}_[0-9]{2}$": format = "yyyy_MM_dd"
        case name =~~ "^[0-9]{2}-[0-9]{2}-[0-9]{4}$": format = "dd-MM-yyyy"
        default: return nil
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = format
        guard let date = df.date(from: name) else { return nil }
        // Reject impossible dates like 13-45-2026 that DateFormatters can rubber-stamp.
        return df.string(from: date) == name ? date : nil
    }

    static func filename(for date: Date) -> String {
        allFilenames(for: date)[0]
    }

    /// Today's filename in every supported format, newest convention first
    /// (`yyyy-MM-dd.md`, `yyyy_MM_dd.md`, `dd-MM-yyyy.md`).
    static func allFilenames(for date: Date) -> [String] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        var out: [String] = []
        for format in ["yyyy-MM-dd", "yyyy_MM_dd", "dd-MM-yyyy"] {
            df.dateFormat = format
            out.append(df.string(from: date) + ".md")
        }
        return out
    }

    static func isJournalFilename(_ filename: String) -> Bool {
        date(fromFilename: filename) != nil
    }

    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}

infix operator =~~ : ComparisonPrecedence
func =~~ (lhs: String, rhs: String) -> Bool {
    lhs.range(of: rhs, options: .regularExpression) != nil
}
