import SwiftUI

/// The Repeat / On / At rows and a preview of the next run, for editing a `ScheduleDraft`.
/// Used by Settings > Schedule and the first-run setup sheet; put it inside a Form `Section`.
struct ScheduleFields: View {
    /// `@Binding` edits the parent's draft directly, so the parent sees every change
    @Binding var draft: ScheduleDraft

    var body: some View {
        Picker("Repeat", selection: $draft.frequency) {
            ForEach(ScheduleDraft.Frequency.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        switch draft.frequency {
        case .daily:
            EmptyView()
        case .weekly:
            LabeledContent("On") {
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { weekday in
                        Toggle(Calendar.current.shortWeekdaySymbols[weekday], isOn: weekdayBinding(weekday))
                            .toggleStyle(.button)
                    }
                }
            }
        case .monthly:
            Stepper("On day \(draft.dayOfMonth) of the month", value: $draft.dayOfMonth, in: 1...28)
        }

        DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)

        if let next = draft.schedule.nextRun(after: .now) {
            LabeledContent("Next run would be", value: next.formatted(date: .complete, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }

    // A custom `Binding(get:set:)` adapts a value to what a control expects: here a
    // DatePicker that edits a Date, and toggles that edit membership of a Set.

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: draft.hour, minute: draft.minute)) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? draft.hour
                draft.minute = parts.minute ?? draft.minute
            }
        )
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { draft.weekdays.contains(weekday) },
            set: { isOn in
                if isOn { draft.weekdays.insert(weekday) } else { draft.weekdays.remove(weekday) }
            }
        )
    }
}
