import SwiftUI
import AppKit

/// Menu bar applet (window style): quick-add a task to today's journal (or
/// schedule it for a picked date) and see/toggle today's open todos without
/// opening the main window.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var quickAdd = ""
    @State private var scheduling = false
    @State private var scheduledDate = JournalDate.startOfDay(Date())

    var body: some View {
        Group {
            if let store = appModel.store {
                vaultPanel(store)
            } else {
                VStack(spacing: 10) {
                    Text("No vault connected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Open DayStream") {
                        openMainWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding()
                .frame(width: 300)
            }
        }
    }

    private func vaultPanel(_ store: VaultStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    openMainWindow()
                } label: {
                    Label("Open DayStream", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            quickAddField

            Divider()

            todoList(store)
        }
        .padding(10)
        .frame(width: 320)
    }

    private var quickAddField: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Quick add a task for today…", text: $quickAdd)
                    .font(.system(size: 13))
                    .onSubmit(submitQuickAdd)
                if !quickAdd.isEmpty {
                    Button(action: submitQuickAdd) {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(scheduling ? "Add to the selected date" : "Add to today's journal")
                }
                Button {
                    scheduling.toggle()
                } label: {
                    Image(systemName: scheduling ? "calendar.badge.checkmark" : "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(scheduling ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(scheduling ? "Add to today instead" : "Schedule for a specific date")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary.opacity(0.35))
            )

            if scheduling {
                DatePicker(
                    "Date",
                    selection: $scheduledDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                .font(.system(size: 12))
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func todoList(_ store: VaultStore) -> some View {
        let todos = todayTodos(store)
        if todos.isEmpty {
            Text("No open tasks for today.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos, id: \.block.id) { item in
                        MenuBarTodoRow(
                            content: item.block.content,
                            indent: item.block.indent,
                            done: false,
                            toggle: {
                                appModel.store?.toggleTodo(
                                    in: item.file,
                                    block: item.block,
                                    syncAcrossNotes: settings.syncTodosAcrossNotes
                                )
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
    }

    private func todayTodos(_ store: VaultStore) -> [(file: VaultFile, block: Block)] {
        let today = JournalDate.startOfDay(Date())
        guard let day = store.days.first(where: { $0.date == today }) else { return [] }
        guard let file = day.editFile else { return [] }
        var out: [(VaultFile, Block)] = []
        func walk(_ nodes: [Block]) {
            for n in nodes {
                if n.todoState == .open { out.append((file, n)) }
                walk(n.children)
            }
        }
        walk(file.blocks)
        return out
    }

    private func submitQuickAdd() {
        let text = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store = appModel.store else { return }
        let target: Date = scheduling ? scheduledDate : Date()
        store.addTask(text, to: target, atTop: false)
        if !store.days.contains(where: { $0.date == JournalDate.startOfDay(target) }) {
            store.reload()
        }
        quickAdd = ""
        scheduling = false
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarTodoRow: View {
    let content: String
    let indent: Int
    let done: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                MarkdownText(content: content)
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(indent) * 12)
    }
}
