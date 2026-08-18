import XCTest
@testable import DayStream

final class NoteFormatterTests: XCTestCase {
    private func utc(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.date(from: s)!
    }

    // MARK: - Timestamps

    func testTimestampRoundTrip() {
        let d = utc("2026-08-18 14:33")
        XCTAssertEqual(NoteFormatter.parseTimestamp(NoteFormatter.timestamp(d)), d)
    }

    func testDurationFormatting() {
        func dur(_ from: String, _ to: String) -> String {
            NoteFormatter.duration(from: utc(from), to: utc(to))
        }
        XCTAssertEqual(dur("2026-08-18 10:00", "2026-08-18 10:00"), "<1m")
        XCTAssertEqual(dur("2026-08-18 10:00", "2026-08-18 10:45"), "45m")
        XCTAssertEqual(dur("2026-08-18 10:00", "2026-08-18 12:00"), "2h")
        XCTAssertEqual(dur("2026-08-18 10:00", "2026-08-18 12:15"), "2h 15m")
        XCTAssertEqual(dur("2026-08-18 10:00", "2026-08-21 10:00"), "3d")
        XCTAssertEqual(dur("2026-08-18 10:00", "2026-08-21 14:00"), "3d 4h")
    }

    // MARK: - Empty bullet removal

    func testRemovingEmptyBullets() {
        let text = "- TODO real\n-\n- \n*\n\t-\n- also real\n"
        let out = NoteFormatter.removingEmptyBullets(text)
        XCTAssertEqual(out.components(separatedBy: "\n").filter { !$0.isEmpty }, ["- TODO real", "- also real"])
    }

    // MARK: - Wikilink group spacing

    func testSpacingWikilinkGroups() {
        let text = "- [[Alpha]]\n\t- sub one\n- [[Beta]]\n\t- sub two\n- plain note\n"
        let out = NoteFormatter.spacingWikilinkGroups(text)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- [[Alpha]]")
        XCTAssertEqual(lines[1], "\t- sub one")
        XCTAssertEqual(lines[2], "", "blank line between the [[Alpha]] group and [[Beta]]")
        XCTAssertEqual(lines[3], "- [[Beta]]")
        XCTAssertEqual(lines[4], "\t- sub two")
        XCTAssertEqual(lines[5], "- plain note", "non-wikilink line follows without an inserted blank")
    }

    func testSpacingKeepsExistingBlankLinesSingle() {
        let text = "- [[Alpha]]\n\n- [[Beta]]\n"
        let out = NoteFormatter.spacingWikilinkGroups(text)
        XCTAssertTrue(out.hasPrefix("- [[Alpha]]\n\n- [[Beta]]"))
        XCTAssertFalse(out.contains("\n\n\n"), "never doubles existing blank lines")
    }

    // MARK: - added:: stamping

    func testStampingAddedTimestamps() {
        let text = "- TODO fresh task\n- TODO stamped\n\tadded:: 2026-08-17 09:00\n- DONE finished\n"
        let now = utc("2026-08-18 10:00")
        let out = NoteFormatter.stampingAddedTimestamps(text, at: now)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- TODO fresh task")
        XCTAssertEqual(lines[1], "\tadded:: " + NoteFormatter.timestamp(now), "missing stamp added under the bullet")
        XCTAssertEqual(lines[2], "- TODO stamped")
        XCTAssertEqual(lines[3], "\tadded:: 2026-08-17 09:00", "existing stamp untouched")
        // DONE task is not stamped.
        let doneRange = out.range(of: "- DONE finished\n")
        XCTAssertNotNil(doneRange)
        let afterDone = out[doneRange!.upperBound...]
        XCTAssertFalse(afterDone.hasPrefix("\tadded::"))
    }

    // MARK: - completed:: stamping

    func testCompletionStampInsertsUnderBullet() {
        let text = "- TODO task\n\t- child note"
        let when = utc("2026-08-18 11:00")
        let out = NoteFormatter.withCompletionStamp(text, blockLineIndex: 0, at: when)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "\tcompleted:: " + NoteFormatter.timestamp(when), "stamp lands between bullet and children")
        XCTAssertEqual(lines[2], "\t- child note")
    }

    func testCompletionStampUpdatesExisting() {
        let text = "- DONE task\n\tcompleted:: 2026-08-18 11:00"
        let when = utc("2026-08-19 09:30")
        let out = NoteFormatter.withCompletionStamp(text, blockLineIndex: 0, at: when)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 2, "no extra line when updating in place")
        XCTAssertTrue(out.contains("\tcompleted:: " + NoteFormatter.timestamp(when)))
    }

    // MARK: - Full ⌘S normalization

    func testNormalizedForSaveCombinesRules() {
        let text = "-\n- TODO write docs\n- [[Project]]\n\t- research\n- [[Next]]\n"
        let now = utc("2026-08-18 16:00")
        let out = NoteFormatter.normalizedForSave(text, isToday: true, now: now)

        XCTAssertFalse(out.hasPrefix("- \n") && out.contains("\n- \n"), "empty bullet removed")
        XCTAssertEqual(out.components(separatedBy: "\n").first, "- TODO write docs")
        XCTAssertTrue(out.contains("\tadded:: " + NoteFormatter.timestamp(now)))
        XCTAssertTrue(out.contains("\n\n- [[Project]]"), "blank line before [[Project]] group")
        XCTAssertTrue(out.contains("\n\n- [[Next]]"), "blank line before [[Next]] group")
        XCTAssertTrue(out.hasSuffix("\n"), "single trailing newline")
    }
}

final class WikiDateTests: XCTestCase {
    func testParsesCommonFormats() {
        let cases = [
            "2026-08-18",
            "Aug 18, 2026",
            "Aug 18th, 2026",
            "August 18th, 2026",
            "august 18 2026",
            "18 Aug 2026",
            "18th August, 2026",
        ]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        for name in cases {
            let parsed = WikiDate.parse(name)
            XCTAssertNotNil(parsed, "should parse: \(name)")
            if let d = parsed {
                XCTAssertEqual(cal.component(.day, from: d), 18)
                XCTAssertEqual(cal.component(.month, from: d), 8)
                XCTAssertEqual(cal.component(.year, from: d), 2026)
            }
        }
    }

    func testRejectsNonDates() {
        for name in ["eval", "", "  ", "not a date at all", "2026-13-01", "Feb 30, 2026", "Aug 2026", "2026-08"] {
            XCTAssertNil(WikiDate.parse(name), "should reject: \(name)")
        }
    }
}

final class RecurringTaskTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    func testDailyIsDueEveryDay() {
        let task = RecurringTask(title: "Plan the day", schedule: .daily)
        XCTAssertTrue(task.isDue(on: date("2026-08-18"), calendar: cal))
        XCTAssertTrue(task.isDue(on: date("2026-08-19"), calendar: cal))
    }

    func testWeeklyOnlyOnItsWeekday() {
        // 2026-08-18 is a Tuesday.
        let task = RecurringTask(title: "Weekly review", schedule: .weekly(weekday: 3))
        XCTAssertTrue(task.isDue(on: date("2026-08-18"), calendar: cal))
        XCTAssertFalse(task.isDue(on: date("2026-08-19"), calendar: cal))
    }

    func testOnceOnlyOnItsDate() {
        let task = RecurringTask(title: "Renew passport", schedule: .once(date: date("2026-09-01")))
        XCTAssertTrue(task.isDue(on: date("2026-09-01"), calendar: cal))
        XCTAssertFalse(task.isDue(on: date("2026-09-02"), calendar: cal))
    }

    func testStorePersistsAcrossInstances() throws {
        let suite = "daystream-tests-recurring-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = RecurringTaskStore(defaults: defaults)
        store.add(RecurringTask(title: "Daily standup notes", schedule: .daily))
        store.add(RecurringTask(title: "One-off", schedule: .once(date: date("2026-09-01"))))

        let reloaded = RecurringTaskStore(defaults: defaults)
        XCTAssertEqual(reloaded.tasks.count, 2)
        XCTAssertTrue(reloaded.tasks.contains { $0.title == "Daily standup notes" && $0.schedule == .daily })

        reloaded.delete(reloaded.tasks[0].id)
        XCTAssertEqual(RecurringTaskStore(defaults: defaults).tasks.count, 1)
    }
}

final class DeadlineTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    func testIsDueOnlyOnItsDay() {
        let d = Deadline(title: "Submit paper", date: date("2026-08-20"))
        XCTAssertTrue(d.isDue(on: date("2026-08-20")))
        XCTAssertFalse(d.isDue(on: date("2026-08-19")))
        XCTAssertFalse(d.isDue(on: date("2026-08-21")))
    }

    func testRelativeLabels() {
        let today = date("2026-08-18")
        XCTAssertEqual(Deadline(title: "a", date: date("2026-08-18")).label(from: today), "Today")
        XCTAssertEqual(Deadline(title: "a", date: date("2026-08-19")).label(from: today), "Tomorrow")
        // 2026-08-18 is a Tuesday; +3 = Friday.
        XCTAssertEqual(Deadline(title: "a", date: date("2026-08-21")).label(from: today), "Fri")
        XCTAssertEqual(Deadline(title: "a", date: date("2026-08-16")).label(from: today), "Overdue 2d")
        XCTAssertTrue(Deadline(title: "a", date: date("2026-09-30")).label(from: today).contains("Sep"))
    }

    func testStorePersistsAndSorts() {
        let suite = "daystream-tests-deadlines-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DeadlineStore(defaults: defaults)
        store.add(Deadline(title: "Late thing", date: date("2026-09-10")))
        store.add(Deadline(title: "Soon", date: date("2026-08-19")))

        let reloaded = DeadlineStore(defaults: defaults)
        XCTAssertEqual(reloaded.deadlines.count, 2)
        XCTAssertEqual(reloaded.sorted.first?.title, "Soon", "soonest deadline first")

        reloaded.delete(reloaded.sorted[0].id)
        XCTAssertEqual(DeadlineStore(defaults: defaults).deadlines.count, 1)
    }

    func testApplyDeadlinesSeedsDueDayOnlyAndIsIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daystream-deadline-\(UUID().uuidString)", isDirectory: true)
        let journals = tmp.appendingPathComponent("journals", isDirectory: true)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = VaultStore(vaultURL: tmp, watchEnabled: false)
        store.reload()

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        let due = df.date(from: "2026-08-18")!

        let deadlines = [
            Deadline(title: "Submit paper", date: JournalDate.startOfDay(due)),
            Deadline(title: "Far future", date: JournalDate.startOfDay(df.date(from: "2026-12-01")!)),
        ]
        XCTAssertEqual(store.applyDeadlines(deadlines, to: due), 1)
        XCTAssertEqual(store.applyDeadlines(deadlines, to: due), 0, "duplicate check prevents re-seeding")

        let filename = JournalDate.filename(for: due)
        let text = try String(contentsOf: journals.appendingPathComponent(filename), encoding: .utf8)
        XCTAssertTrue(text.contains("- TODO Submit paper"))
        XCTAssertFalse(text.contains("Far future"))
    }
}

final class VaultTaskAndSearchTests: XCTestCase {
    private var tmp: URL!
    private var journals: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daystream-tasks-\(UUID().uuidString)", isDirectory: true)
        journals = tmp.appendingPathComponent("journals", isDirectory: true)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("pages", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() -> VaultStore {
        let store = VaultStore(vaultURL: tmp, watchEnabled: false)
        store.reload()
        return store
    }

    func testAddTaskAppendsWithStampAndDedupes() throws {
        try "- existing\n".write(to: journals.appendingPathComponent("2026-08-18.md"), atomically: true, encoding: .utf8)
        let store = makeStore()

        XCTAssertTrue(store.addTask("Email Alice", to: try utc("2026-08-18"), atTop: false))
        let text = try String(contentsOf: journals.appendingPathComponent("2026-08-18.md"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "- existing")
        XCTAssertEqual(lines[1], "- TODO Email Alice")
        XCTAssertTrue(lines[2].hasPrefix("\tadded:: "))
        XCTAssertNotNil(NoteFormatter.parseTimestamp(String(lines[2].dropFirst("\tadded:: ".count))))

        // Second add of the same task is a no-op.
        XCTAssertFalse(store.addTask("email alice", to: try utc("2026-08-18"), atTop: false))
        XCTAssertEqual(
            try String(contentsOf: journals.appendingPathComponent("2026-08-18.md"), encoding: .utf8),
            text)
    }

    func testAddTaskAtTopPrepends() throws {
        let store = makeStore()
        let day = JournalDate.startOfDay(Date())
        XCTAssertTrue(store.addTask("Top task", to: day, atTop: true))
        let text = try String(contentsOf: journals.appendingPathComponent(JournalDate.filename(for: day)), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("- TODO Top task\n\tadded:: "))
    }

    func testApplyRecurringTasksIsIdempotent() throws {
        let store = makeStore()
        let day = Date()
        let weekday = Calendar.current.component(.weekday, from: day)
        let tasks = [
            RecurringTask(title: "Plan the day", schedule: .daily),
            RecurringTask(title: "Weekly review", schedule: .weekly(weekday: weekday)),
            RecurringTask(title: "Not today", schedule: .weekly(weekday: weekday == 1 ? 2 : 1)),
        ]

        XCTAssertEqual(store.applyRecurringTasks(tasks, to: day), 2)
        let first = try String(contentsOf: journals.appendingPathComponent(JournalDate.filename(for: day)), encoding: .utf8)
        XCTAssertTrue(first.contains("- TODO Plan the day"))
        XCTAssertTrue(first.contains("- TODO Weekly review"))
        XCTAssertFalse(first.contains("Not today"))

        XCTAssertEqual(store.applyRecurringTasks(tasks, to: day), 0, "duplicate check prevents re-adding")
        XCTAssertEqual(
            try String(contentsOf: journals.appendingPathComponent(JournalDate.filename(for: day)), encoding: .utf8),
            first)
    }

    func testToggleTodoStampsCompletion() throws {
        try "- TODO Email Alice\n".write(to: journals.appendingPathComponent("2026-08-18.md"), atomically: true, encoding: .utf8)
        let store = makeStore()
        let target = JournalDate.startOfDay(try utc("2026-08-18"))
        let day = store.days.first { $0.date == target }!
        let file = day.files[0]

        store.toggleTodo(in: file, block: file.blocks[0], syncAcrossNotes: false)

        let text = try String(contentsOf: journals.appendingPathComponent("2026-08-18.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("- DONE Email Alice"))
        XCTAssertTrue(text.contains("\tcompleted:: "), "completing a task records when it happened")
        let stamp = text.components(separatedBy: "\n")[1]
        XCTAssertNotNil(NoteFormatter.parseTimestamp(String(stamp.dropFirst("\tcompleted:: ".count))))
    }

    func testSearchFindsJournalsAndPages() throws {
        try "- TODO eval the model\n".write(to: journals.appendingPathComponent("2026-08-17.md"), atomically: true, encoding: .utf8)
        try "- plain day\n".write(to: journals.appendingPathComponent("2026-08-16.md"), atomically: true, encoding: .utf8)
        try "# Eval Notes\nnotes about eval\n".write(
            to: tmp.appendingPathComponent("pages").appendingPathComponent("eval notes.md"),
            atomically: true, encoding: .utf8)

        let store = makeStore()
        let hits = store.search("eval")
        XCTAssertGreaterThanOrEqual(hits.count, 3)
        XCTAssertTrue(hits.contains { $0.date != nil && $0.lineText.contains("eval the model") })
        XCTAssertTrue(hits.contains { $0.isPage && $0.title == "eval notes" && $0.lineText == "Page" })
        XCTAssertTrue(hits.contains { $0.isPage && $0.lineText.contains("notes about eval") })
        XCTAssertTrue(store.search("nothing-matches-this").isEmpty)
    }

    func testAllPageNamesCombinesFilesAndLinks() throws {
        try "- see [[Ideas]] and [[eval]]\n".write(to: journals.appendingPathComponent("2026-08-17.md"), atomically: true, encoding: .utf8)
        try "".write(to: tmp.appendingPathComponent("pages").appendingPathComponent("Books.md"), atomically: true, encoding: .utf8)

        let store = makeStore()
        let names = store.allPageNames()
        XCTAssertTrue(names.contains("Ideas"))
        XCTAssertTrue(names.contains("eval"))
        XCTAssertTrue(names.contains("Books"))
    }

    private func utc(_ s: String) throws -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: s) else { throw NSError(domain: "test", code: 1) }
        // Raw instant, matching how filename formatters work in VaultStore.
        return d
    }
}
