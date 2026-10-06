import Foundation
import EventKit
import Observation

// MARK: - Snapshots & state (pure; unit-tested without EventKit)

struct ReminderSnapshot: Equatable {
    var id: String
    var title: String
    var isCompleted: Bool
}

struct VaultTaskSnapshot: Equatable {
    /// Normalized full title (header included) — the join key between
    /// vault and Reminders.
    var key: String
    /// Reminder title: `HEADER/task` when the task sits under a section,
    /// else the bare task text.
    var title: String
    /// Bare task text — what `VaultStore.syncTodoState` matches by.
    var content: String

    init(key: String, title: String, content: String? = nil) {
        self.key = key
        self.title = title
        self.content = content ?? title
    }
}

/// Title-keyed mirror memory. Reminder ids churn across relaunches and
/// devices, but the vault's task text is the stable key the rest of the
/// app already syncs by, so the whole state machine rides on it.
///
/// - knownKeys: every task title ever seen while syncing — distinguishes
///   "vault task closed (complete its reminder)" from "brand-new reminder
///   (import it as a todo)".
/// - mirroredKeys: titles we created or adopted a reminder for — a missing
///   reminder for a mirrored title means the user deleted it on purpose.
/// - closedKeys: titles whose closed vault state has been acknowledged
///   against a completed reminder — an unchecked reminder for a closed
///   title therefore means the user wants it reopened.
/// - userDeletedKeys: titles whose reminder the user deleted while the
///   task was still open; not re-created until the title closes and
///   reopens (so deletion never resurrects reminders).
struct RemindersSyncState: Codable, Equatable {
    var knownKeys: Set<String> = []
    var mirroredKeys: Set<String> = []
    var closedKeys: Set<String> = []
    var userDeletedKeys: Set<String> = []
}

struct RemindersSyncPlan: Equatable {
    var createTitles: [String] = []
    var completeIDs: [String] = []
    var uncompleteIDs: [String] = []
    var vaultDoneTitles: [String] = []
    var vaultReopenTitles: [String] = []
    var importTitles: [String] = []
    var nextState = RemindersSyncState()

    var summary: String {
        var parts: [String] = []
        if !createTitles.isEmpty { parts.append("\(createTitles.count) sent to Reminders") }
        if !importTitles.isEmpty { parts.append("\(importTitles.count) imported") }
        if !completeIDs.isEmpty { parts.append("\(completeIDs.count) completed") }
        if !uncompleteIDs.isEmpty { parts.append("\(uncompleteIDs.count) reopened") }
        if !vaultDoneTitles.isEmpty { parts.append("\(vaultDoneTitles.count) task\(vaultDoneTitles.count == 1 ? "" : "s") checked") }
        if !vaultReopenTitles.isEmpty { parts.append("\(vaultReopenTitles.count) task\(vaultReopenTitles.count == 1 ? "" : "s") reopened") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
    }
}

// MARK: - Pure planner

enum RemindersSync {

    /// Distinct open tasks (TODO/DOING/LATER/NOW) over `days` (newest
    /// first, only days >= cutoff): the same dedupe rule as the app's
    /// open-task counters — a carried-forward title counts once, newest
    /// occurrence supplying the display title. Tasks carry a section
    /// prefix in the title (`HEADER/task`) from their nearest non-task
    /// ancestor (indented `- [[ADMIN]]` sections, plain parents), else
    /// from the heading line governing their position (`## [[OPS]]`,
    /// bare `[[OPS]]` lines) — so same-titled tasks in different
    /// sections mirror as distinct reminders.
    static func openTasks(days: [JournalDay], cutoff: Date) -> [VaultTaskSnapshot] {
        var seen = Set<String>()
        var out: [VaultTaskSnapshot] = []
        for day in days where day.date >= cutoff {
            for file in day.files {
                let headers = runningHeaders(in: file.text)
                func walk(_ nodes: [Block], section: String?) {
                    for node in nodes {
                        if node.todoState == .open {
                            let lineHeader = headers.indices.contains(node.lineIndex)
                                ? headers[node.lineIndex] : nil
                            let effective = section ?? lineHeader
                            let title = effective.map { "\($0)/\(node.content)" } ?? node.content
                            let key = BlockTree.normalize(title)
                            if !key.isEmpty, seen.insert(key).inserted {
                                out.append(VaultTaskSnapshot(key: key, title: title, content: node.content))
                            }
                        }
                        // A task's children keep the outer section; only
                        // non-task blocks (section bullets, plain parents)
                        // start their own. Heading context needs no
                        // propagation — each line reads its own.
                        let childSection = node.todoState == .none
                            ? (sectionName(of: node) ?? section)
                            : section
                        walk(node.children, section: childSection)
                    }
                }
                walk(file.blocks, section: nil)
            }
        }
        return out
    }

    /// Running heading context per line. The block parser swallows a
    /// heading that follows a bullet as that bullet's continuation line,
    /// so `## X` boundaries are invisible to a block-only walk — they
    /// must come from a line-level scan. Only zero-indent heading lines
    /// (`## X`) and bare `[[wikilink]]` lines count: bullet-form headers
    /// (`- [[ADMIN]]`) own only their indented children, per the app's
    /// own header conventions.
    static func runningHeaders(in text: String) -> [String?] {
        let lines = text.components(separatedBy: "\n")
        var out = [String?](repeating: nil, count: lines.count)
        var current: String?
        var fenced = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if BlockTree.fenceMarker(trimmed) != nil {
                fenced.toggle()
                out[i] = current
                continue
            }
            if !fenced {
                let topLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                if topLevel, let name = headerLineName(trimmed) {
                    current = name
                }
            }
            out[i] = current
        }
        return out
    }

    /// Header name for a zero-indent line: a standalone `[[wikilink]]`
    /// (bare or after heading marks) yields the link target; otherwise
    /// only `#`-prefixed lines count, as their text. Nil for plain text.
    static func headerLineName(_ trimmed: String) -> String? {
        let isHeading = trimmed.hasPrefix("#")
        let body: String
        if isHeading {
            guard let r = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) else {
                return nil
            }
            body = String(trimmed[r.upperBound...])
        } else {
            body = trimmed
        }
        guard !body.isEmpty else { return nil }
        if body.range(of: "^\\[\\[[^\\[\\]]+\\]\\]$", options: .regularExpression) != nil {
            return WikiName.wikilinkTargets(in: body).first
        }
        return isHeading ? body : nil
    }

    /// Display name of a non-task block used as a section: its first
    /// wikilink target (`- [[ADMIN]]` → ADMIN), else the content with
    /// heading marks stripped.
    static func sectionName(of block: Block) -> String? {
        if let link = WikiName.wikilinkTargets(in: block.content).first { return link }
        let stripped = block.content
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    /// Splits a `HEADER/task` reminder title at the first slash. Both
    /// sides non-empty; callers decide whether the header is real.
    static func splitHeader(_ title: String) -> (header: String, task: String)? {
        guard let slash = title.firstIndex(of: "/") else { return nil }
        let header = String(title[..<slash]).trimmingCharacters(in: .whitespaces)
        let task = String(title[title.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard !header.isEmpty, !task.isEmpty else { return nil }
        return (header, task)
    }

    /// One mirror pass: pure transition from (vault tasks, list snapshots,
    /// prior state) to the actions that bring both sides in line, plus the
    /// state to persist for the next pass. Convergent — feeding the
    /// post-action world back in yields an empty plan.
    static func plan(
        vaultOpen: [VaultTaskSnapshot],
        reminders: [ReminderSnapshot],
        state: RemindersSyncState
    ) -> RemindersSyncPlan {
        var plan = RemindersSyncPlan(nextState: state)
        var next = plan.nextState
        next.knownKeys.formUnion(vaultOpen.map(\.key))

        var incompleteByKey: [String: ReminderSnapshot] = [:]
        var completedByKey: [String: ReminderSnapshot] = [:]
        for r in reminders {
            let k = BlockTree.normalize(r.title)
            guard !k.isEmpty else { continue }
            if r.isCompleted {
                if completedByKey[k] == nil { completedByKey[k] = r }
            } else if incompleteByKey[k] == nil {
                incompleteByKey[k] = r
            }
        }
        let openKeys = Set(vaultOpen.map(\.key))

        for task in vaultOpen {
            let k = task.key
            if next.userDeletedKeys.contains(k) { continue }
            if incompleteByKey[k] != nil {
                next.closedKeys.remove(k)
                next.mirroredKeys.insert(k)
            } else if let r = completedByKey[k] {
                if next.closedKeys.contains(k) {
                    // Vault reopened (carry-forward, recurrence, uncheck in
                    // a note) under a reminder we had acknowledged as
                    // closed — reopen the reminder too.
                    plan.uncompleteIDs.append(r.id)
                    next.closedKeys.remove(k)
                } else {
                    // Completed on the Reminders side while the vault says
                    // open — the user checked it there. Vault writes match
                    // by bare task text (syncTodoState), not the title.
                    plan.vaultDoneTitles.append(task.content)
                    next.closedKeys.insert(k)
                    next.mirroredKeys.insert(k)
                }
            } else if next.mirroredKeys.contains(k) {
                // We mirrored this title before and now no reminder with it
                // exists in the list: the user deleted it — don't resurrect.
                next.userDeletedKeys.insert(k)
            } else {
                plan.createTitles.append(task.title)
                next.mirroredKeys.insert(k)
            }
        }

        for r in reminders where !r.isCompleted {
            let k = BlockTree.normalize(r.title)
            guard !k.isEmpty, !openKeys.contains(k) else { continue }
            if next.closedKeys.contains(k) {
                // Unchecked in Reminders after the mirror completed it;
                // strip the header so the vault write matches bare tasks.
                plan.vaultReopenTitles.append(splitHeader(r.title)?.task ?? r.title)
                next.closedKeys.remove(k)
            } else if next.knownKeys.contains(k) {
                // Was an open vault task earlier; now closed (done or
                // deleted) — complete its reminder.
                plan.completeIDs.append(r.id)
                next.closedKeys.insert(k)
            } else {
                // Created by the user in the Reminders list — import it.
                plan.importTitles.append(r.title)
                next.knownKeys.insert(k)
                next.mirroredKeys.insert(k)
            }
        }

        // A deleted reminder is forgiven once its title isn't open anymore,
        // so a recurrence later mirrors again.
        next.userDeletedKeys = Set(next.userDeletedKeys.filter { openKeys.contains($0) })
        plan.nextState = next
        return plan
    }
}

// MARK: - Engine

/// Owns the EventKit side of the mirror: access, the target list, change
/// listeners and the reconcile loop. The vault side stays untouched except
/// through `VaultStore.syncTodoState`/`addTask`, so mirror writes reuse the
/// store's generation-guarded batching.
@Observable
final class RemindersSyncEngine {
    private(set) var accessGranted = false
    private(set) var accessDenied = false
    private(set) var isRunning = false
    private(set) var lastSync: Date?
    private(set) var lastSummary: String?
    private(set) var lastError: String?
    private(set) var listOptions: [(id: String, title: String)] = []

    private var store: VaultStore?
    private var _eventStore: EKEventStore?
    private var eventStore: EKEventStore {
        if let s = _eventStore { return s }
        let s = EKEventStore()
        _eventStore = s
        return s
    }

    private static let stateKey = "daystream.remindersSyncState"
    private var state = RemindersSyncState()
    /// Serializes EventKit work; EKEventStore and its objects are not safe
    /// to touch from multiple threads.
    private let queue = DispatchQueue(label: "daystream.reminders", qos: .utility)
    private var reconcileItem: DispatchWorkItem?
    private var changeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var isEnabled = false
    /// Mirror-initiated vault writes echo back through onVaultMutated;
    /// kicks inside this window are the engine's own footsteps.
    private var lastSelfVaultWrite: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(RemindersSyncState.self, from: data) {
            state = saved
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        timer?.invalidate()
    }

    func attach(store: VaultStore) {
        self.store = store
        store.onVaultMutated = { [weak self] in self?.noteVaultMutated() }
    }

    func detach() {
        store?.onVaultMutated = nil
        store = nil
    }

    func enable() async {
        guard !isEnabled else { return }
        isEnabled = true
        let es = eventStore
        let granted = (try? await es.requestFullAccessToReminders()) ?? false
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
            self.ensureList()
            self.refreshListOptionsLocked()
            self.startObservers()
            self.reconcileNow()
        }
    }

    func disable() {
        isEnabled = false
        queue.async { [weak self] in
            self?.stopObservers()
        }
    }

    /// Reminders lists the user can mirror into, for the Settings picker.
    func refreshListOptions() {
        queue.async { [weak self] in
            self?.refreshListOptionsLocked()
        }
    }

    func reconcileNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconcileItem?.cancel()
            self.reconcile()
        }
    }

    /// Debounced: typing saves and watcher reloads all funnel through
    /// onVaultMutated, so the mirror pass must not run per keystroke.
    func scheduleReconcile() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconcileItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reconcile() }
            self.reconcileItem = item
            self.queue.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }

    // MARK: Private

    private func noteVaultMutated() {
        let recent = lastSelfVaultWrite.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        guard !recent else { return }
        scheduleReconcile()
    }

    private func refreshListOptionsLocked() {
        guard accessGranted else { return }
        let options = eventStore.calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { ($0.calendarIdentifier, $0.title) }
        DispatchQueue.main.async { [weak self] in
            self?.listOptions = options
        }
    }

    /// Uses the selected list when it still exists, adopts a list named
    /// DayStream, else creates one (iCloud source preferred so the list
    /// reaches the user's phone).
    private func ensureList() {
        let settings = AppSettings.shared
        if !settings.remindersListID.isEmpty,
           eventStore.calendar(withIdentifier: settings.remindersListID) != nil {
            return
        }
        if let existing = eventStore.calendars(for: .reminder)
            .first(where: { $0.title.caseInsensitiveCompare("DayStream") == .orderedSame }) {
            settings.remindersListID = existing.calendarIdentifier
            return
        }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = "DayStream"
        guard let source = eventStore.sources.first(where: { $0.sourceType == .calDAV })
            ?? eventStore.sources.first(where: { $0.sourceType == .local })
            ?? eventStore.defaultCalendarForNewReminders()?.source else {
            setError("No calendar source is available for a Reminders list.")
            return
        }
        calendar.source = source
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            settings.remindersListID = calendar.calendarIdentifier
        } catch {
            setError("Couldn't create a DayStream Reminders list: \(error.localizedDescription)")
        }
    }

    private func startObservers() {
        guard changeObserver == nil, timer == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            self?.scheduleReconcile()
        }
        // Safety net: the vault hook covers DayStream-side edits and
        // EKEventStoreChanged covers the Reminders side, but a periodic
        // pass heals anything a missed event would have left behind.
        // Timer creation must happen on the main run loop's own thread —
        // an off-main add can silently never fire (see AppModel).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.scheduleReconcile()
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
            self?.reconcileItem?.cancel()
            self?.reconcileItem = nil
        }
    }

    private func reconcile() {
        guard isEnabled, accessGranted, let store else { return }
        let listID = AppSettings.shared.remindersListID
        guard let calendar = eventStore.calendar(withIdentifier: listID) else {
            setError("The synced Reminders list is no longer available — pick another in Settings.")
            return
        }
        setMain {
            // Fresh pass: errors from previous passes don't linger when this
            // one succeeds; errors raised below overwrite this in order.
            self.isRunning = true
            self.lastError = nil
        }
        // Snapshot `days` on the main thread (observable state), everything
        // else stays on the queue. No main→queue sync exists anywhere, so
        // this sync hop cannot deadlock.
        var days: [JournalDay] = []
        DispatchQueue.main.sync { days = store.days }
        let vaultOpen = RemindersSync.openTasks(days: days, cutoff: VaultStore.openCountCutoff())
        let fetched = fetchReminders(in: calendar)
        let snapshots = fetched.map {
            ReminderSnapshot(id: $0.calendarItemIdentifier,
                             title: $0.title ?? "",
                             isCompleted: $0.isCompleted)
        }
        let plan = RemindersSync.plan(vaultOpen: vaultOpen, reminders: snapshots, state: state)
        apply(plan, fetched: fetched, calendar: calendar)
        state = plan.nextState
        saveState()
        setMain {
            self.isRunning = false
            self.lastSync = Date()
            self.lastSummary = plan.summary
        }
    }

    /// The SDK only offers the callback form of the reminder fetch; block
    /// on it from the engine queue. The completion lands on an EventKit
    /// queue, never this one, so the wait cannot deadlock.
    private func fetchReminders(in calendar: EKCalendar) -> [EKReminder] {
        final class Box { var reminders: [EKReminder] = [] }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let predicate = eventStore.predicateForReminders(in: [calendar])
        _ = eventStore.fetchReminders(matching: predicate) { reminders in
            box.reminders = reminders ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return box.reminders
    }

    private func apply(_ plan: RemindersSyncPlan, fetched: [EKReminder], calendar: EKCalendar) {
        if !plan.createTitles.isEmpty || !plan.completeIDs.isEmpty || !plan.uncompleteIDs.isEmpty {
            var byID: [String: EKReminder] = [:]
            for r in fetched {
                if byID[r.calendarItemIdentifier] == nil { byID[r.calendarItemIdentifier] = r }
            }
            do {
                for title in plan.createTitles {
                    let r = EKReminder(eventStore: eventStore)
                    r.calendar = calendar
                    r.title = title
                    try eventStore.save(r, commit: true)
                }
                for id in plan.completeIDs {
                    guard let r = byID[id] else { continue }
                    r.isCompleted = true
                    try eventStore.save(r, commit: true)
                }
                for id in plan.uncompleteIDs {
                    guard let r = byID[id] else { continue }
                    r.isCompleted = false
                    try eventStore.save(r, commit: true)
                }
            } catch {
                setError("Reminders sync failed: \(error.localizedDescription)")
            }
        }
        if !plan.vaultDoneTitles.isEmpty || !plan.vaultReopenTitles.isEmpty || !plan.importTitles.isEmpty {
            // Reuse the store's cross-note echo and duplicate-checked insert
            // paths; their writes funnel back through onVaultMutated, which
            // the lastSelfVaultWrite window keeps from looping.
            lastSelfVaultWrite = Date()
            let done = plan.vaultDoneTitles
            let reopen = plan.vaultReopenTitles
            let imports = plan.importTitles
            DispatchQueue.main.async { [weak self] in
                guard let self, let store = self.store else { return }
                for title in done {
                    store.syncTodoState(taskContent: title, to: .done, excluding: nil)
                }
                for title in reopen {
                    store.syncTodoState(taskContent: title, to: .open, excluding: nil)
                }
                for title in imports {
                    // A `HEADER/task` reminder files the task under that
                    // section in today's note; addRecurringTask creates the
                    // `- [[HEADER]]` bullet when missing and stamps added::
                    // exactly like every other inserted task.
                    if let split = RemindersSync.splitHeader(title) {
                        _ = store.addRecurringTask(split.task, to: Date(), header: split.header)
                    } else {
                        _ = store.addTask(title, to: Date(), atTop: false)
                    }
                }
            }
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func setMain(_ update: @escaping () -> Void) {
        DispatchQueue.main.async { update() }
    }

    private func setError(_ message: String) {
        setMain { self.lastError = message }
    }
}
