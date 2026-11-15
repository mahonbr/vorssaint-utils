// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The add/edit sheet. A task is validated here: a blank command cannot be
/// saved, and every schedule value is clamped before it reaches the model.
struct ScheduledTaskEditorView: View {
    @State private var task: ScheduledTask
    let isNew: Bool
    let strings: ScheduledTasksFeatureStrings
    let save: (ScheduledTask) -> Void
    let delete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    init(task: ScheduledTask,
         isNew: Bool,
         strings: ScheduledTasksFeatureStrings,
         save: @escaping (ScheduledTask) -> Void,
         delete: (() -> Void)?) {
        _task = State(initialValue: task)
        self.isNew = isNew
        self.strings = strings
        self.save = save
        self.delete = delete
    }

    private var commandIsEmpty: Bool {
        task.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? strings.newTaskTitle : strings.editTaskTitle)
                .font(.headline)

            Form {
                TextField(strings.nameLabel, text: $task.name,
                          prompt: Text(strings.namePlaceholder))
                shellRow
                frequencyRow
                scheduleRows
                if task.schedule.frequency != .atLoad && task.schedule.frequency != .idle {
                    Toggle(strings.catchUpToggle, isOn: $task.catchesUp)
                }
                Toggle(strings.enabledToggle, isOn: $task.isEnabled)
                commandEditor
            }
            .formStyle(.grouped)

            HStack {
                if delete != nil {
                    Button(strings.deleteTask) {
                        confirmingDelete = true
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button(strings.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? strings.add : strings.save) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(commandIsEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 620)
        .alert(String(format: strings.deleteTitleFormat, task.displayName(strings)),
               isPresented: $confirmingDelete) {
            Button(strings.deleteTask, role: .destructive) {
                delete?()
                dismiss()
            }
            Button(strings.cancel, role: .cancel) {}
        } message: {
            Text(strings.deleteMessage)
        }
    }

    // MARK: - Rows

    private var shellRow: some View {
        Picker(strings.shellLabel, selection: $task.shell) {
            ForEach(ScheduledTaskShell.allCases) { shell in
                Text(shell.title(strings)).tag(shell)
            }
        }
        .pickerStyle(.menu)
    }

    private var frequencyRow: some View {
        Picker(strings.scheduleLabel, selection: $task.schedule.frequency) {
            ForEach(ScheduledTaskFrequency.allCases) { frequency in
                Text(frequency.title(strings)).tag(frequency)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var scheduleRows: some View {
        switch task.schedule.frequency {
        case .atLoad:
            Text(strings.atLoadCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .minutes:
            HStack {
                Text(strings.everyLabel)
                Spacer()
                TextField("", value: $task.schedule.intervalMinutes,
                          formatter: Self.integerFormatter)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(strings.minutesLabel)
            }
        case .idle:
            HStack {
                Text(strings.afterLabel)
                Spacer()
                TextField("", value: $task.schedule.intervalMinutes,
                          formatter: Self.integerFormatter)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(strings.minutesIdleLabel)
            }
        case .daily:
            timeRow
        case .weekly:
            weekdayRow
            timeRow
        case .monthly:
            dayOfMonthRow
            timeRow
        }
    }

    private var weekdayRow: some View {
        Picker(strings.onLabel, selection: $task.schedule.weekday) {
            ForEach(weekdayOptions, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
    }

    private var dayOfMonthRow: some View {
        Picker(strings.onDayLabel, selection: $task.schedule.dayOfMonth) {
            ForEach(1...31, id: \.self) { day in
                Text(String(day)).tag(day)
            }
        }
        .pickerStyle(.menu)
    }

    private var timeRow: some View {
        HStack {
            Text(strings.atLabel)
            Spacer()
            Picker("", selection: $task.schedule.hour) {
                ForEach(hourOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110, alignment: .trailing)
            Picker("", selection: $task.schedule.minute) {
                ForEach(0..<60, id: \.self) { minute in
                    Text(String(format: ":%02d", minute)).tag(minute)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 80, alignment: .trailing)
        }
    }

    private var commandEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(strings.commandLabel)
            TextEditor(text: $task.command)
                .font(.body.monospaced())
                .frame(minHeight: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            Text(strings.commandCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Choices

    private var weekdayOptions: [(label: String, value: Int)] {
        Calendar.current.standaloneWeekdaySymbols.enumerated().map { index, name in
            (label: name.capitalized, value: index + 1)
        }
    }

    /// Every hour, labelled the way this Mac's clock writes it: "9:00 AM" on a
    /// twelve hour system and "09:00" on a twenty four hour one.
    private var hourOptions: [(label: String, value: Int)] {
        (0..<24).map { hour in
            let date = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                                  hour: hour, minute: 0))
                ?? Date()
            return (label: Self.timeFormatter.string(from: date), value: hour)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: ScheduledTaskScheduleSettings.intervalRange.lowerBound)
        formatter.maximum = NSNumber(value: ScheduledTaskScheduleSettings.intervalRange.upperBound)
        return formatter
    }()

    // MARK: - Actions

    private func commit() {
        var saved = task
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.command = saved.command.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.schedule.intervalMinutes = ScheduledTaskScheduleSettings.clampedInterval(
            saved.schedule.intervalMinutes)
        saved.schedule.hour = min(max(saved.schedule.hour, 0), 23)
        saved.schedule.minute = min(max(saved.schedule.minute, 0), 59)
        saved.schedule.weekday = min(max(saved.schedule.weekday, 1), 7)
        saved.schedule.dayOfMonth = min(max(saved.schedule.dayOfMonth, 1), 31)
        save(saved)
        dismiss()
    }
}
