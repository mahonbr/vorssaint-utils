// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The Scheduled Tasks pane: one card per task, with its switch, schedule,
/// last run and manual controls. Adding and editing happen in a sheet so the
/// list stays a list.
struct ScheduledTasksSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var model = ScheduledTasksModel.shared
    @ObservedObject private var scheduler = ScheduledTasksScheduler.shared
    @ObservedObject private var runner = ScheduledTaskRunner.shared
    @AppStorage(DefaultsKey.scheduledTasksEnabled) private var scheduleEnabled = false

    @State private var creating = false
    @State private var editing: ScheduledTask?

    private var strings: ScheduledTasksFeatureStrings {
        FeatureStrings.scheduledTasks(l10n.language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                enableCard

                if model.tasks.isEmpty {
                    emptyCard
                } else {
                    ForEach(model.tasks) { task in
                        taskCard(task)
                    }
                }

                Text(strings.storageCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { scheduler.syncWithPreferences() }
        .onChange(of: scheduleEnabled) { _, _ in
            scheduler.syncWithPreferences()
        }
        .sheet(isPresented: $creating) {
            ScheduledTaskEditorView(task: ScheduledTask(),
                                    isNew: true,
                                    strings: strings,
                                    save: save,
                                    delete: nil)
        }
        .sheet(item: $editing) { task in
            ScheduledTaskEditorView(task: task,
                                    isNew: false,
                                    strings: strings,
                                    save: save,
                                    delete: {
                                        runner.stop(id: task.id)
                                        model.remove(id: task.id)
                                    })
        }
    }

    // MARK: - Cards

    private var introCard: some View {
        SettingsCard {
            SettingsRow(symbol: "clock.arrow.circlepath",
                        title: strings.introTitle,
                        caption: strings.introCaption) {
                Button {
                    creating = true
                } label: {
                    Label(strings.addTask, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            Text(strings.introWarning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enableCard: some View {
        SettingsCard {
            SettingsRow(symbol: "calendar.badge.clock",
                        title: strings.scheduleEnabled,
                        caption: strings.scheduleEnabledCaption) {
                Toggle(strings.scheduleEnabled, isOn: $scheduleEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var emptyCard: some View {
        SettingsCard(title: strings.emptyTitle) {
            Text(strings.emptyCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: enabledBinding(task))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(String(format: strings.enableTaskFormat,
                                               task.displayName(strings)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.displayName(strings))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(ScheduledTaskSchedule.summary(for: task.schedule, strings: strings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    statusLine(task)
                }

                Spacer(minLength: 8)

                if runner.isRunning(task.id) {
                    Button(strings.stop) { runner.stop(id: task.id) }
                        .controlSize(.small)
                } else {
                    Button(strings.runNow) { runNow(task) }
                        .controlSize(.small)
                        .disabled(!scheduleEnabled || !task.isRunnable)
                }

                Button {
                    editing = task
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(format: strings.editTaskFormat, task.displayName(strings)))
                .accessibilityLabel(String(format: strings.editTaskFormat,
                                           task.displayName(strings)))
            }

            if !task.isRunnable {
                Text(strings.needsCommand)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The running state, then the next fire or why there is none, then what
    /// happened last. Kept to a few short lines so a long list still scans.
    private func statusLine(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(scheduleState(task))
                .font(.caption2)
                .foregroundStyle(runner.isRunning(task.id) ? Color.accentColor : .secondary)
            if let last = lastRunText(task) {
                Text(last)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func scheduleState(_ task: ScheduledTask) -> String {
        if runner.isRunning(task.id) { return strings.running }
        guard scheduleEnabled else { return strings.featureOff }
        guard task.isEnabled else { return strings.off }
        if task.schedule.frequency == .atLoad { return strings.atLoadState }
        if task.schedule.frequency == .idle {
            let minutes = ScheduledTaskScheduleSettings.clampedInterval(
                task.schedule.intervalMinutes)
            return minutes == 1 ? strings.idleStateOne
                : String(format: strings.idleStateManyFormat, minutes)
        }
        if let next = scheduler.nextFire[task.id] {
            return String(format: strings.nextRunFormat, Self.runFormatter.string(from: next))
        }
        return strings.waitingForRun
    }

    private func lastRunText(_ task: ScheduledTask) -> String? {
        guard task.lastRun > 0 else { return nil }
        let when = Self.runFormatter.string(
            from: Date(timeIntervalSince1970: task.lastRun))
        guard let outcome = task.lastOutcome else {
            return String(format: strings.lastRunFormat, when)
        }
        if outcome == .failed, let code = task.lastExitCode {
            return String(format: strings.lastRunFailedFormat, when, code)
        }
        return String(format: strings.lastRunOutcomeFormat, when, outcome.title(strings))
    }

    // MARK: - Actions

    /// Saves the editor's fields but keeps the run record the scheduler may
    /// have written while the sheet was open. The editor never edits those
    /// three values, so an old snapshot must not erase a run.
    private func save(_ edited: ScheduledTask) {
        let merged = model.tasks.first(where: { $0.id == edited.id })
            .map(edited.preservingRunRecord(from:)) ?? edited
        model.upsert(merged)
    }

    private func runNow(_ task: ScheduledTask) {
        runner.start(task) { outcome, exitCode in
            model.recordRun(id: task.id, outcome: outcome, exitCode: exitCode)
        }
    }

    /// The card's switch edits the model's copy, not the value the card was
    /// drawn from, so two quick clicks cannot resurrect a stale task.
    private func enabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(
            get: { model.tasks.first(where: { $0.id == task.id })?.isEnabled ?? task.isEnabled },
            set: { model.setEnabled($0, for: task.id) }
        )
    }

    private static let runFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
