import SwiftUI

struct CalendarView: View {
    @Environment(AppModel.self) private var appModel
    @State private var displayedMonth: Date = JournalDate.startOfDay(Date())

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1 // Sunday, matching the vault's :start-of-week 6
        return c
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: displayedMonth)
    }

    private var daysWithNotes: [Date: Bool] {
        guard let store = appModel.store else { return [:] }
        var out: [Date: Bool] = [:]
        for day in store.days {
            out[day.date] = day.hasOpenTodos
        }
        return out
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            let weeks = monthGrid()
            ForEach(weeks, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { date in
                        if let date {
                            dayCell(date)
                        } else {
                            Color.clear.frame(height: 30)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isToday = date == JournalDate.startOfDay(Date())
        let openTodos = daysWithNotes[date] == true
        let hasNote = daysWithNotes[date] != nil

        Button {
            if hasNote {
                appModel.reveal(day: date)
            } else {
                appModel.createDayNote(for: date)
            }
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                    .foregroundStyle(
                        isToday ? Color.white
                        : hasNote ? Color.primary
                        : Color.secondary.opacity(0.6)
                    )
                Circle()
                    .fill(openTodos ? Color.orange : Color.secondary.opacity(0.55))
                    .frame(width: 4, height: 4)
                    .opacity(hasNote ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isToday ? Color.accentColor : .clear)
            )
        }
        .buttonStyle(.plain)
        .help(hasNote ? "Jump to \(dateString(date))" : "Create a note for \(dateString(date))")
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
    }

    private func monthGrid() -> [[Date?]] {
        let interval = calendar.dateInterval(of: .month, for: displayedMonth) ?? DateInterval(start: displayedMonth, duration: 0)
        let firstDay = interval.start
        let firstWeekdayIndex = calendar.component(.weekday, from: firstDay) - calendar.firstWeekday
        let leading = (firstWeekdayIndex + 7) % 7

        var dates: [Date?] = Array(repeating: nil, count: leading)
        var current = firstDay
        while current < interval.end {
            dates.append(JournalDate.startOfDay(current, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        while dates.count % 7 != 0 {
            dates.append(nil)
        }
        return stride(from: 0, to: dates.count, by: 7).map { Array(dates[$0..<min($0 + 7, dates.count)]) }
    }

    private func moveMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedMonth = next
            }
        }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}
