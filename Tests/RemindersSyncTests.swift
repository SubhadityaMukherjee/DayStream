import XCTest
@testable import DayStream

final class RemindersSyncTests: XCTestCase {
    private func day(_ iso: String, text: String) -> JournalDay {
        let f = ISO8601DateFormatter()
        let date = f.date(from: iso + "T00:00:00Z")!
        return JournalDay(date: date, files: [VaultFile(url: URL(fileURLWithPath: "/tmp/\(iso).md"), date: date, text: text)])
    }

    private let cutoff = ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!

    private func key(_ s: String) -> String { BlockTree.normalize(s) }

    // MARK: - openTasks

    func testOpenTasksDedupesNewestOccurrenceWins() {
        let days = [
            day("2026-10-06", text: "- TODO Ship the report\n"),
            day("2026-10-05", text: "- TODO Ship  the report!\n- TODO Old task\n"),
        ]
        let tasks = RemindersSync.openTasks(days: days, cutoff: cutoff)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first?.title, "Ship the report")
        XCTAssertTrue(tasks.contains { $0.key == key("old task") })
    }

    func testOpenTasksRespectsCutoffAndSkipsDoneAndNonTasks() {
        let days = [
            day("2026-10-06", text: "- DONE Done task\n- LATER Waiting task\n- Plain bullet\n"),
            day("2026-05-01", text: "- TODO Ancient task\n"),
        ]
        let tasks = RemindersSync.openTasks(days: days, cutoff: cutoff)
        XCTAssertEqual(tasks.map(\.key), [key("waiting task")])
    }

    func testOpenTasksWalksNestedBlocks() {
        let days = [day("2026-10-06", text: "- [[ADMIN]]\n\t- TODO Recurring thing\n")]
        let tasks = RemindersSync.openTasks(days: days, cutoff: cutoff)
        XCTAssertEqual(tasks.map(\.key), [key("recurring thing")])
    }

    // MARK: - plan: push

    func testInitialMirrorCreatesReminders() {
        let vault = [VaultTaskSnapshot(key: key("buy milk"), title: "Buy milk")]
        let plan = RemindersSync.plan(vaultOpen: vault, reminders: [], state: RemindersSyncState())
        XCTAssertEqual(plan.createTitles, ["Buy milk"])
        XCTAssertEqual(plan.nextState.mirroredKeys, [key("buy milk")])
        XCTAssertEqual(plan.nextState.knownKeys, [key("buy milk")])
    }

    func testInSyncPassIsEmptyAndConverges() {
        let vault = [VaultTaskSnapshot(key: key("buy milk"), title: "Buy milk")]
        let reminders = [ReminderSnapshot(id: "r1", title: "Buy milk", isCompleted: false)]
        let state = RemindersSyncState(knownKeys: [key("buy milk")], mirroredKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: vault, reminders: reminders, state: state)
        XCTAssertEqual(plan.createTitles, [])
        XCTAssertEqual(plan.completeIDs, [])
        XCTAssertEqual(plan.vaultDoneTitles, [])
        XCTAssertEqual(plan.nextState, state)
    }

    // MARK: - plan: completion both ways

    func testReminderCompletedMarksVaultTaskDone() {
        let vault = [VaultTaskSnapshot(key: key("buy milk"), title: "Buy milk")]
        let reminders = [ReminderSnapshot(id: "r1", title: "Buy milk", isCompleted: true)]
        let state = RemindersSyncState(knownKeys: [key("buy milk")], mirroredKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: vault, reminders: reminders, state: state)
        XCTAssertEqual(plan.vaultDoneTitles, ["Buy milk"])
        XCTAssertTrue(plan.nextState.closedKeys.contains(key("buy milk")))
    }

    func testVaultTaskClosedCompletesReminder() {
        let reminders = [ReminderSnapshot(id: "r1", title: "Buy milk", isCompleted: false)]
        let state = RemindersSyncState(knownKeys: [key("buy milk")], mirroredKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: [], reminders: reminders, state: state)
        XCTAssertEqual(plan.completeIDs, ["r1"])
        XCTAssertTrue(plan.nextState.closedKeys.contains(key("buy milk")))
    }

    func testUncheckedReminderAfterCloseReopensTask() {
        let reminders = [ReminderSnapshot(id: "r1", title: "Buy milk", isCompleted: false)]
        let state = RemindersSyncState(knownKeys: [key("buy milk")], mirroredKeys: [key("buy milk")],
                                       closedKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: [], reminders: reminders, state: state)
        XCTAssertEqual(plan.vaultReopenTitles, ["Buy milk"])
        XCTAssertFalse(plan.nextState.closedKeys.contains(key("buy milk")))
    }

    func testReopenedVaultTaskUncompletesReminder() {
        let vault = [VaultTaskSnapshot(key: key("buy milk"), title: "Buy milk")]
        let reminders = [ReminderSnapshot(id: "r1", title: "Buy milk", isCompleted: true)]
        let state = RemindersSyncState(knownKeys: [key("buy milk")], mirroredKeys: [key("buy milk")],
                                       closedKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: vault, reminders: reminders, state: state)
        XCTAssertEqual(plan.uncompleteIDs, ["r1"])
        XCTAssertFalse(plan.nextState.closedKeys.contains(key("buy milk")))
    }

    // MARK: - plan: deletion guard

    func testDeletedReminderIsNotResurrectedWhileTaskOpen() {
        let vault = [VaultTaskSnapshot(key: key("buy milk"), title: "Buy milk")]
        let state = RemindersSyncState(knownKeys: [key("buy milk")], mirroredKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: vault, reminders: [], state: state)
        XCTAssertEqual(plan.createTitles, [], "mirrored title with no reminder = user deleted it")
        XCTAssertEqual(plan.nextState.userDeletedKeys, [key("buy milk")])

        // Still open, still no reminder: stays silent.
        let plan2 = RemindersSync.plan(vaultOpen: vault, reminders: [], state: plan.nextState)
        XCTAssertEqual(plan2.createTitles, [])

        // Task closes: the blacklist entry is forgiven.
        let plan3 = RemindersSync.plan(vaultOpen: [], reminders: [], state: plan.nextState)
        XCTAssertTrue(plan3.nextState.userDeletedKeys.isEmpty)
    }

    // MARK: - plan: import

    func testForeignReminderIsImported() {
        let reminders = [ReminderSnapshot(id: "r9", title: "Call the dentist", isCompleted: false)]
        let plan = RemindersSync.plan(vaultOpen: [], reminders: reminders, state: RemindersSyncState())
        XCTAssertEqual(plan.importTitles, ["Call the dentist"])
    }

    func testReminderMatchingHistoricVaultTitleIsCompletedNotImported() {
        // A title the vault used to have open: its reminder completes
        // (mirror), it doesn't re-enter the vault.
        let reminders = [ReminderSnapshot(id: "r9", title: "Buy milk", isCompleted: false)]
        let state = RemindersSyncState(knownKeys: [key("buy milk")])
        let plan = RemindersSync.plan(vaultOpen: [], reminders: reminders, state: state)
        XCTAssertEqual(plan.importTitles, [])
        XCTAssertEqual(plan.completeIDs, ["r9"])
    }

    func testCompletedForeignRemindersAreIgnored() {
        let reminders = [
            ReminderSnapshot(id: "r1", title: "Old business", isCompleted: true),
            ReminderSnapshot(id: "r2", title: "", isCompleted: false),
        ]
        let plan = RemindersSync.plan(vaultOpen: [], reminders: reminders, state: RemindersSyncState())
        XCTAssertEqual(plan.importTitles, [])
        XCTAssertEqual(plan.completeIDs, [])
        XCTAssertEqual(plan.createTitles, [])
    }

    // MARK: - plan: full round trip converges

    func testRoundTripConvergesAfterApplyingBothSides() {
        let k = key("buy milk")
        var vaultOpen = [VaultTaskSnapshot(key: k, title: "Buy milk")]
        var reminders: [ReminderSnapshot] = []
        var state = RemindersSyncState()

        // 1. Mirror creates the reminder.
        var plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.createTitles, ["Buy milk"])
        state = plan.nextState
        reminders.append(ReminderSnapshot(id: "r1", title: "Buy milk", isCompleted: false))

        // 2. Steady state.
        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.summary, "Up to date")
        state = plan.nextState

        // 3. User checks it in Reminders: vault task flips done, reminder stays completed.
        reminders[0].isCompleted = true
        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.vaultDoneTitles, ["Buy milk"])
        state = plan.nextState
        vaultOpen = []

        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.summary, "Up to date")
        state = plan.nextState

        // 4. User unchecks it: task reopens in the vault…
        reminders[0].isCompleted = false
        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.vaultReopenTitles, ["Buy milk"])
        state = plan.nextState
        vaultOpen = [VaultTaskSnapshot(key: k, title: "Buy milk")]

        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.summary, "Up to date")
        state = plan.nextState

        // 5. …and closing it from the vault side completes the reminder again.
        vaultOpen = []
        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.completeIDs, ["r1"])
        state = plan.nextState
        reminders[0].isCompleted = true

        plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: reminders, state: state)
        XCTAssertEqual(plan.summary, "Up to date")
    }
}
