import Foundation

/// Parses wikilink targets that are really journal dates — Logseq renders
/// date links like `[[Aug 18th, 2026]]`, and ISO `[[2026-08-18]]` is common
/// too. Clicking such a link jumps to that day in the stream instead of
/// opening a page.
enum WikiDate {
    private static let months: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, name) in Calendar.current.monthSymbols.enumerated() {
            m[name.lowercased()] = i + 1
            m[String(name.prefix(3)).lowercased()] = i + 1
        }
        m["sept"] = 9
        return m
    }()

    /// Local start-of-day for the date the name represents, or nil when the
    /// name isn't a date. Accepts `2026-08-18`, `Aug 18, 2026`,
    /// `August 18th, 2026`, `18 Aug 2026` (case-insensitive).
    static func parse(_ name: String) -> Date? {
        let s = name.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 40 else { return nil }

        if let g = captures(s, #"^(\d{4})-(\d{1,2})-(\d{1,2})$"#),
           let y = Int(g[0]), let mo = Int(g[1]), let d = Int(g[2]) {
            return makeDate(year: y, month: mo, day: d)
        }
        // Month-first: Aug 18th, 2026 / August 18 2026
        if let g = captures(s, #"^([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\s*,?\s*(\d{4})$"#),
           let mo = months[g[0].lowercased()], let d = Int(g[1]), let y = Int(g[2]) {
            return makeDate(year: y, month: mo, day: d)
        }
        // Day-first: 18 Aug 2026 / 18th August, 2026
        if let g = captures(s, #"^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)\.?\s*,?\s*(\d{4})$"#),
           let d = Int(g[0]), let mo = months[g[1].lowercased()], let y = Int(g[2]) {
            return makeDate(year: y, month: mo, day: d)
        }
        return nil
    }

    private static func captures(_ s: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1
        else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (1900...3000).contains(year) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        // date(from:) normalizes overflow (Feb 30 -> Mar 2); reject that.
        guard let date = cal.date(from: c) else { return nil }
        let roundTrip = cal.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
            ? cal.startOfDay(for: date)
            : nil
    }
}
