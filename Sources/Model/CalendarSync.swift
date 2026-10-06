import Foundation
import EventKit
import Observation

// MARK: - Pure merge logic (no EventKit; unit-tested)

struct CalendarEventSnapshot: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
}

enum CalendarSync {

    static let headerName = "TODAY"
    /// Property line anchoring a section bullet to its calendar event:
    /// `event:: <calendarItemIdentifier>#<start epoch>`. The editor
    /// collapses property lines to zero height, so sections stay clean.
    static let markerKey = "event"

    static func markerValue(for e: CalendarEventSnapshot, id: String) -> String {
        "\(id)#\(Int(e.start.timeIntervalSince1970))"
    }

    /// `Title, 9:00 AM` — timed events; all-day events have no time part.
    static func eventLine(_ e: CalendarEventSnapshot, timeString: (Date) -> String) -> String {
        let title = e.title.trimmingCharacters(in: .whitespaces)
        return e.isAllDay ? title : "\(title), \(timeString(e.start))"
    }

    static func isHeaderLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("#") { return true }
        let body = (t.hasPrefix("- ") || t.hasPrefix("* ")) ? String(t.dropFirst(2)) : t
        return body.range(of: "^\\[\\[[^\\[\\]]+\\]\\]$", options: .regularExpression) != nil
    }

    /// Line index just past the TODAY section's last member — where new
    /// event lines belong. Bullet-form headers (`- [[TODAY]]`) end at the
    /// first non-blank line at their indent or shallower; heading-form
    /// sections end at the next header line of any shape.
    static func sectionEndIndex(headerIndex: Int, lines: [String]) -> Int {
        let headerIsBullet = isBulletLine(lines[headerIndex])
        let headerIndent = BlockTree.leadingWhitespaceUnits(lines[headerIndex])
        var i = headerIndex + 1
        while i < lines.count {
            let line = lines[i]
            if isHeaderLine(line) { break }
            if headerIsBullet,
               !line.trimmingCharacters(in: .whitespaces).isEmpty,
               BlockTree.leadingWhitespaceUnits(line) <= headerIndent {
                break
            }
            i += 1
        }
        return i
    }

    struct MergeResult: Equatable {
        var text: String
        var added = 0
        var updated = 0
    }

    /// One merge pass: adds today's events under the TODAY header (created
    /// at the top of the note when missing, `- [[TODAY]]` bullet form like
    /// every other seeded section) and keeps entries current — a moved
    /// event rewrites its line instead of duplicating. Entries are plain
    /// bullets (`Title, 9:00 AM`), deduped per event by the hidden
    /// `event::` marker, so they never join the open-task counters, the
    /// carry-forward pool or the Reminders mirror. Returns nil when the
    /// note already reflects `events`.
    static func mergedText(
        todayText: String,
        events: [CalendarEventSnapshot],
        ids: [String],
        timeString: (Date) -> String
    ) -> MergeResult? {
        // Pair and prune: no empty titles, no duplicate events (the same
        // event can surface twice from duplicated calendars).
        var pairs: [(event: CalendarEventSnapshot, id: String)] = []
        var seenMarkers = Set<String>()
        for (e, id) in zip(events, ids) {
            guard !e.title.trimmingCharacters(in: .whitespaces).isEmpty,
                  seenMarkers.insert(markerValue(for: e, id: id)).inserted else { continue }
            pairs.append((e, id))
        }
        pairs.sort { lhs, rhs in
            lhs.event.start != rhs.event.start
                ? lhs.event.start < rhs.event.start
                : lhs.event.title.localizedCaseInsensitiveCompare(rhs.event.title) == .orderedAscending
        }

        let lines = todayText.components(separatedBy: "\n")

        guard let headerIndex = VaultStore.recurringHeaderLineIndex(header: headerName, in: todayText) else {
            guard !pairs.isEmpty else { return nil }
            var section = ["- [[\(headerName)]]"]
            for pair in pairs {
                section.append("\t- " + eventLine(pair.event, timeString: timeString))
                section.append("\t\t\(markerKey):: " + markerValue(for: pair.event, id: pair.id))
            }
            let trimmed = todayText.trimmingCharacters(in: .whitespacesAndNewlines)
            let joined = section.joined(separator: "\n")
            let newText = trimmed.isEmpty ? joined + "\n" : joined + "\n\n" + trimmed + "\n"
            return MergeResult(text: newText, added: pairs.count)
        }

        // Existing entries: event id → (bullet line, marker line, marker value).
        let end = sectionEndIndex(headerIndex: headerIndex, lines: lines)
        var byID: [String: (bullet: Int, marker: Int, value: String)] = [:]
        var lastBullet: Int?
        for i in (headerIndex + 1)..<end {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if isBulletLine(t) {
                lastBullet = i
            } else if t.hasPrefix("\(markerKey):: ") {
                let value = String(t.dropFirst("\(markerKey):: ".count))
                let id = String(value.prefix { $0 != "#" })
                if !id.isEmpty, let bullet = lastBullet {
                    byID[id] = (bullet, i, value)
                }
            }
        }

        var updatedLines = lines
        var newLines: [String] = []
        var added = 0
        var updated = 0
        // Match the section's own convention: bullet-form headers keep
        // indented children, heading-form sections take top-level bullets.
        let headerIsBullet = isBulletLine(lines[headerIndex].trimmingCharacters(in: .whitespaces))
        let bulletIndent = headerIsBullet ? "\t" : ""
        let markerIndent = headerIsBullet ? "\t\t" : "\t"
        for pair in pairs {
            let value = markerValue(for: pair.event, id: pair.id)
            if let existing = byID[pair.id] {
                guard existing.value != value else { continue }
                // Moved or retitled event: rewrite in place, keeping the
                // line's own indentation.
                updatedLines[existing.bullet] = lead(of: updatedLines[existing.bullet])
                    + "- " + eventLine(pair.event, timeString: timeString)
                updatedLines[existing.marker] = lead(of: updatedLines[existing.marker])
                    + "\(markerKey):: \(value)"
                updated += 1
            } else {
                newLines.append(bulletIndent + "- " + eventLine(pair.event, timeString: timeString))
                newLines.append(markerIndent + "\(markerKey):: \(value)")
                added += 1
            }
        }
        guard added > 0 || updated > 0 else { return nil }
        if !newLines.isEmpty {
            // Insert at the section's last member, not past trailing blank
            // lines, so entries stay attached to their section.
            var insertAt = end
            while insertAt > headerIndex + 1,
                  updatedLines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            updatedLines.insert(contentsOf: newLines, at: insertAt)
        }
        return MergeResult(text: updatedLines.joined(separator: "\n"), added: added, updated: updated)
    }

    private static func isBulletLine(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func lead(of line: String) -> String {
        String(line.prefix { $0 == "\t" || $0 == " " })
    }
}

// MARK: - Engine

/// Owns the EventKit side of the today-section: calendar access, the
/// day's event fetch, and change listeners. Writes go through
/// `VaultStore.write` on the canonical today file, so the store's
/// generation guarding and watcher suppression apply.
@Observable
final class CalendarSyncEngine {
    private(set) var accessGranted = false
    private(set) var accessDenied = false
    private(set) var isRunning = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?

    private var store: VaultStore?
    private var _eventStore: EKEventStore?
    private var eventStore: EKEventStore {
        if let s = _eventStore { return s }
        let s = EKEventStore()
        _eventStore = s
        return s
    }

    private let queue = DispatchQueue(label: "daystream.calendar", qos: .utility)
    private var refreshItem: DispatchWorkItem?
    private var changeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var isEnabled = false

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        timer?.invalidate()
    }

    func attach(store: VaultStore) {
        self.store = store
    }

    func detach() {
        store = nil
    }

    func enable() async {
        guard !isEnabled else { return }
        isEnabled = true
        let es = eventStore
        let granted = (try? await es.requestFullAccessToEvents()) ?? false
        guard granted else {
            accessDenied = true
            accessGranted = false
            isEnabled = false
            return
        }
        accessDenied = false
        accessGranted = true
        queue.async { [weak self] in
            guard let self else { return }
            self.startObservers()
            self.refreshLocked()
        }
    }

    func disable() {
        isEnabled = false
        queue.async { [weak self] in
            self?.stopObservers()
        }
    }

    /// Immediate pass — app launch, day rollover, Sync Now.
    func refresh() {
        queue.async { [weak self] in
            self?.refreshLocked()
        }
    }

    /// Debounced pass — EKEventStoreChanged notifications.
    func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.refreshLocked() }
            self.refreshItem = item
            self.queue.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }

    // MARK: Private

    private func startObservers() {
        guard changeObserver == nil, timer == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        // Backstop: calendar edits normally fire EKEventStoreChanged, but
        // a periodic pass heals anything a missed event would leave
        // behind. Timer creation must happen on the main run loop's own
        // thread — an off-main add can silently never fire (see AppModel).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
                self?.scheduleRefresh()
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    private func stopObservers() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        queue.async { [weak self] in
            self?.refreshItem?.cancel()
            self?.refreshItem = nil
        }
    }

    private func refreshLocked() {
        guard isEnabled, accessGranted, let store else { return }
        setMain {
            self.isRunning = true
            self.lastError = nil
        }
        // Local day window: notes are local-day files.
        let dayStart = JournalDate.startOfDay(Date())
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86400)
        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        var events: [CalendarEventSnapshot] = []
        var ids: [String] = []
        for e in eventStore.events(matching: predicate) {
            guard e.status != .canceled,
                  let title = e.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let start = e.startDate else { continue }
            let end = e.endDate ?? start
            if e.isAllDay {
                // All-day events may merely span today (multi-day trips).
                guard start < dayEnd, end > dayStart else { continue }
            } else {
                // Timed events belong to the day they start in.
                guard start >= dayStart, start < dayEnd else { continue }
            }
            events.append(CalendarEventSnapshot(title: title, start: start, end: end, isAllDay: e.isAllDay))
            ids.append(e.calendarItemIdentifier)
        }

        // Snapshot today's canonical file on the main thread (observable
        // state + file I/O), merge on the queue, write back on main. No
        // main→queue sync exists anywhere, so the sync hop can't deadlock.
        var url: URL?
        var text = ""
        DispatchQueue.main.sync {
            let ensured = store.ensureTodayFile()
            url = ensured.url
            text = ensured.text
        }
        guard let url else { return }
        guard let result = CalendarSync.mergedText(todayText: text, events: events, ids: ids,
                                                   timeString: Self.timeString) else {
            setMain {
                self.isRunning = false
                self.lastSync = Date()
                self.lastSummary = events.isEmpty ? "No events today" : "Up to date"
            }
            return
        }
        let summary = Self.summary(added: result.added, updated: result.updated)
        let target = url
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = self.store else { return }
            store.write(text: result.text, to: target)
        }
        setMain {
            self.isRunning = false
            self.lastSync = Date()
            self.lastSummary = summary
        }
    }

    private static func summary(added: Int, updated: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added) event\(added == 1 ? "" : "s")") }
        if updated > 0 { parts.append("Updated \(updated) event\(updated == 1 ? "" : "s")") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static func timeString(_ d: Date) -> String {
        timeFormatter.string(from: d)
    }

    private func setMain(_ update: @escaping () -> Void) {
        DispatchQueue.main.async { update() }
    }
}
