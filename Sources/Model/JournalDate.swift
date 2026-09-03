import Foundation

/// Parses journal filenames. Supports the three formats found in real Logseq vaults:
/// `yyyy-MM-dd.md` (ISO, used for new files), `yyyy_MM_dd.md` (Logseq default),
/// and `dd-MM-yyyy.md` (custom, day-first). Non-date files are rejected.
enum JournalDate {
    static let newFileFormat = "yyyy-MM-dd"

    /// Cached per-format formatters: `date(fromFilename:)` runs for every
    /// file on every vault reload, and creating DateFormatters in that loop
    /// dominates the reload cost on large vaults. Main-thread use only.
    private static let utcFormatters: [String: DateFormatter] = {
        var out: [String: DateFormatter] = [:]
        for format in ["yyyy-MM-dd", "yyyy_MM_dd", "dd-MM-yyyy"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = format
            out[format] = df
        }
        return out
    }()

    /// Precompiled filename-shape patterns: `=~~` compiled a fresh ICU regex
    /// per call, which dominated `date(fromFilename:)` on large vaults.
    private static let nameShapes: [(regex: NSRegularExpression, format: String)] = [
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}$": "yyyy-MM-dd",
        "^[0-9]{4}_[0-9]{2}_[0-9]{2}$": "yyyy_MM_dd",
        "^[0-9]{2}-[0-9]{2}-[0-9]{4}$": "dd-MM-yyyy",
    ].compactMap { pattern, format in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, format) }
    }

    static func matchesShape(_ filename: String, format: String) -> Bool {
        let name = (filename as NSString).deletingPathExtension
        let full = NSRange(location: 0, length: (name as NSString).length)
        return nameShapes.contains { shape in
            shape.format == format && shape.regex.firstMatch(in: name, range: full) != nil
        }
    }

    static func date(fromFilename filename: String) -> Date? {
        let name = (filename as NSString).deletingPathExtension
        let ns = name as NSString
        let format: String? = nameShapes.first { shape in
            shape.regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
        }?.format
        guard let format, let df = utcFormatters[format] else { return nil }
        guard let date = df.date(from: name) else { return nil }
        // Reject impossible dates like 13-45-2026 that DateFormatters can rubber-stamp.
        return df.string(from: date) == name ? date : nil
    }

    static func filename(for date: Date) -> String {
        allFilenames(for: date)[0]
    }

    /// Today's filename in every supported format, newest convention first
    /// (`yyyy-MM-dd.md`, `yyyy_MM_dd.md`, `dd-MM-yyyy.md`).
    ///
    /// Rendered in the *local* timezone: callers pass local-day instants
    /// (often `startOfDay`, i.e. local midnight — whose UTC day is the
    /// previous day in UTC+ zones), and the name must match the calendar
    /// day the user means. Parsing (`date(fromFilename:)`) stays UTC-based
    /// so file names always round-trip to the same day key.
    ///
    /// Local-day filename formatters, cached per current timezone (rebuilt
    /// if the system timezone changes). `allFilenames` runs per search hit,
    /// per mention and per `ensureDayFile`, so per-call DateFormatter
    /// allocation was a measurable cost.
    private static var localFormatters: (timezone: TimeZone, formatters: [DateFormatter])?

    static func allFilenames(for date: Date) -> [String] {
        let tz = TimeZone.current
        if localFormatters?.timezone != tz {
            localFormatters = (tz, ["yyyy-MM-dd", "yyyy_MM_dd", "dd-MM-yyyy"].map { format in
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = tz
                df.dateFormat = format
                return df
            })
        }
        return localFormatters!.formatters.map { $0.string(from: date) + ".md" }
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
