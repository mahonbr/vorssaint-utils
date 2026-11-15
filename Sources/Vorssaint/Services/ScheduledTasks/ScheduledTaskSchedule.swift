// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The calendar math behind a task's schedule, kept away from the timer so
/// every boundary can be pinned by a test.
enum ScheduledTaskSchedule {
    /// How long after launch or wake a missed run is caught up. Not zero, so
    /// opening Vorssaint stays snappy.
    static let catchUpDelay: TimeInterval = 10

    /// How long after the scheduler arms at launch the at-load tasks run.
    static let atLoadDelay: TimeInterval = 5

    /// The next moment `task` should fire strictly after `now`. At-load tasks
    /// return nil because the scheduler owns their one launch-time fire.
    ///
    /// A run counts as missed when the occurrence after `lastRun` is already
    /// past. Catch-up then aims at `now + catchUpDelay`; without it, the next
    /// occurrence after `now` is used, so a Mac that was off for a week does
    /// not replay every missed day.
    static func nextFireDate(after now: Date,
                             lastRun: Date?,
                             task: ScheduledTask,
                             calendar: Calendar = .current) -> Date? {
        guard task.isRunnable, task.isEnabled else { return nil }
        switch task.schedule.frequency {
        case .atLoad, .idle:
            return nil
        case .minutes:
            let interval = TimeInterval(
                ScheduledTaskScheduleSettings.clampedInterval(task.schedule.intervalMinutes) * 60)
            let base = lastRun ?? now
            let candidate = base.addingTimeInterval(interval)
            guard candidate <= now else { return candidate }
            return task.catchesUp
                ? now.addingTimeInterval(catchUpDelay)
                : now.addingTimeInterval(interval)
        case .daily, .weekly, .monthly:
            let base = lastRun ?? now
            if let candidate = calendarFireDate(after: base,
                                                schedule: task.schedule,
                                                calendar: calendar),
               candidate > now {
                return candidate
            }
            if task.catchesUp {
                return now.addingTimeInterval(catchUpDelay)
            }
            return calendarFireDate(after: now,
                                    schedule: task.schedule,
                                    calendar: calendar)
        }
    }

    /// The next daily, weekly or monthly occurrence strictly after `date`.
    /// Interval and at-load schedules have no calendar occurrence.
    static func calendarFireDate(after date: Date,
                                 schedule: ScheduledTaskScheduleSettings,
                                 calendar: Calendar = .current) -> Date? {
        switch schedule.frequency {
        case .daily, .weekly:
            var components = DateComponents()
            components.hour = min(max(schedule.hour, 0), 23)
            components.minute = min(max(schedule.minute, 0), 59)
            if schedule.frequency == .weekly {
                components.weekday = min(max(schedule.weekday, 1), 7)
            }
            return calendar.nextDate(after: date, matching: components,
                                     matchingPolicy: .nextTime)
        case .monthly:
            return nextMonthlyFireDate(after: date,
                                       day: schedule.dayOfMonth,
                                       hour: schedule.hour,
                                       minute: schedule.minute,
                                       calendar: calendar)
        case .atLoad, .minutes, .idle:
            return nil
        }
    }

    /// The next monthly occurrence strictly after `date`. A day the month does
    /// not have means that month's last day, so "the 31st" still runs in
    /// February instead of skipping the month.
    static func nextMonthlyFireDate(after date: Date,
                                    day: Int,
                                    hour: Int,
                                    minute: Int,
                                    calendar: Calendar = .current) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
        let wantedDay = min(max(day, 1), 31)
        let wantedHour = min(max(hour, 0), 23)
        let wantedMinute = min(max(minute, 0), 59)
        // This month and the next two cover every boundary: this month's
        // occurrence may still be ahead, or it may have passed and the next
        // month may be shorter than the chosen day.
        for offset in 0...2 {
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: month),
                  let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
            else { continue }
            var components = calendar.dateComponents([.year, .month], from: monthStart)
            components.day = min(wantedDay, dayRange.count)
            components.hour = wantedHour
            components.minute = wantedMinute
            components.second = 0
            if let candidate = calendar.date(from: components), candidate > date {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Idle

    /// The tasks whose idle threshold has been met and that have not already
    /// run in this idle period.
    static func idleTasksDue(_ tasks: [ScheduledTask],
                             idleSeconds: TimeInterval,
                             alreadyRun: Set<String>,
                             running: Set<String>) -> [ScheduledTask] {
        tasks.filter { task in
            task.isEnabled && task.isRunnable
                && task.schedule.frequency == .idle
                && idleSeconds >= idleThreshold(for: task)
                && !alreadyRun.contains(task.id)
                && !running.contains(task.id)
        }
    }

    /// The ids whose idle period has ended because the person used the Mac
    /// again. A task still running keeps its id until it finishes, so it cannot
    /// start a second run from the same idle period.
    static func idleTasksToReset(_ tasks: [ScheduledTask],
                                 idleSeconds: TimeInterval,
                                 running: Set<String>) -> Set<String> {
        Set(tasks.filter { task in
            task.schedule.frequency == .idle
                && idleSeconds < idleThreshold(for: task)
                && !running.contains(task.id)
        }.map(\.id))
    }

    /// The idle threshold in seconds, clamped like the interval it shares.
    static func idleThreshold(for task: ScheduledTask) -> TimeInterval {
        TimeInterval(ScheduledTaskScheduleSettings.clampedInterval(
            task.schedule.intervalMinutes) * 60)
    }

    // MARK: - Display

    /// A one-line description for the pane and the editor.
    static func summary(for schedule: ScheduledTaskScheduleSettings,
                        strings: ScheduledTasksFeatureStrings,
                        calendar: Calendar = .current) -> String {
        switch schedule.frequency {
        case .atLoad:
            return strings.whenVorssaintStarts
        case .minutes:
            let minutes = ScheduledTaskScheduleSettings.clampedInterval(schedule.intervalMinutes)
            return minutes == 1 ? strings.everyMinute
                : String(format: strings.everyMinutesFormat, minutes)
        case .idle:
            let minutes = ScheduledTaskScheduleSettings.clampedInterval(schedule.intervalMinutes)
            return minutes == 1 ? strings.afterMinuteIdle
                : String(format: strings.afterMinutesIdleFormat, minutes)
        case .daily:
            let time = timeString(hour: schedule.hour,
                                  minute: schedule.minute,
                                  calendar: calendar)
            return String(format: strings.dailyAtFormat, time)
        case .weekly:
            let symbols = calendar.standaloneWeekdaySymbols
            let index = min(max(schedule.weekday, 1), symbols.count) - 1
            let weekday = symbols.indices.contains(index) ? symbols[index].capitalized : ""
            let time = timeString(hour: schedule.hour,
                                  minute: schedule.minute,
                                  calendar: calendar)
            return String(format: strings.weeklyOnAtFormat, weekday, time)
        case .monthly:
            let day = min(max(schedule.dayOfMonth, 1), 31)
            let time = timeString(hour: schedule.hour,
                                  minute: schedule.minute,
                                  calendar: calendar)
            return String(format: strings.monthlyOnDayAtFormat, day, time)
        }
    }

    /// The system's short time style, so the pane reads the way the clock in
    /// the menu bar does. The calendar's zone is used because the tests pin a
    /// calendar that is not the machine's.
    private static func timeString(hour: Int, minute: Int, calendar: Calendar) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = min(max(hour, 0), 23)
        components.minute = min(max(minute, 0), 59)
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", min(max(hour, 0), 23), min(max(minute, 0), 59))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
}
