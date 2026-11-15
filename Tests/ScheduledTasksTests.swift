// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The scheduled task calendar math, the stored file's clamping and the
/// model's round trip. No timer is armed and no process is started.
enum ScheduledTasksTests {
    static func run(_ suite: TestSuite) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")

        func date(_ year: Int, _ month: Int, _ day: Int,
                  _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day,
                                               hour: hour, minute: minute))!
        }

        func task(_ frequency: ScheduledTaskFrequency,
                  interval: Int = 30,
                  hour: Int = 9,
                  minute: Int = 0,
                  weekday: Int = 2,
                  dayOfMonth: Int = 1,
                  catchesUp: Bool = true,
                  isEnabled: Bool = true,
                  command: String = "echo hello") -> ScheduledTask {
            var schedule = ScheduledTaskScheduleSettings()
            schedule.frequency = frequency
            schedule.intervalMinutes = interval
            schedule.hour = hour
            schedule.minute = minute
            schedule.weekday = weekday
            schedule.dayOfMonth = dayOfMonth
            return ScheduledTask(name: "Task", command: command, schedule: schedule,
                                 catchesUp: catchesUp, isEnabled: isEnabled)
        }

        // MARK: Daily

        let daily = task(.daily, hour: 9, minute: 30)
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 8, 0), lastRun: nil, task: daily, calendar: calendar)
            == date(2026, 11, 15, 9, 30),
            "a daily task fires later the same day")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 10, 0),
            lastRun: date(2026, 11, 15, 9, 30), task: daily, calendar: calendar)
            == date(2026, 11, 16, 9, 30),
            "a daily task that already ran waits for tomorrow")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 10, 0),
            lastRun: date(2026, 11, 14, 9, 30), task: daily, calendar: calendar)
            == date(2026, 11, 15, 10, 0).addingTimeInterval(ScheduledTaskSchedule.catchUpDelay),
            "a missed daily run is caught up shortly after launch")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 10, 0),
            lastRun: date(2026, 11, 14, 9, 30),
            task: task(.daily, hour: 9, minute: 30, catchesUp: false), calendar: calendar)
            == date(2026, 11, 16, 9, 30),
            "without catch-up a missed daily run waits for the next occurrence")

        // MARK: Weekly

        let weekly = task(.weekly, hour: 9, minute: 0, weekday: 2)
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 12, 0), lastRun: nil, task: weekly, calendar: calendar)
            == date(2026, 11, 16, 9, 0),
            "a weekly task picks the next matching weekday")

        // MARK: Monthly

        suite.expect(ScheduledTaskSchedule.nextMonthlyFireDate(
            after: date(2026, 2, 1), day: 31, hour: 9, minute: 0, calendar: calendar)
            == date(2026, 2, 28, 9, 0),
            "a monthly task on the 31st clamps to the short month's last day")
        suite.expect(ScheduledTaskSchedule.nextMonthlyFireDate(
            after: date(2026, 1, 20), day: 15, hour: 9, minute: 0, calendar: calendar)
            == date(2026, 2, 15, 9, 0),
            "a monthly task whose day already passed waits for next month")
        suite.expect(ScheduledTaskSchedule.nextMonthlyFireDate(
            after: date(2026, 1, 1), day: 15, hour: 9, minute: 0, calendar: calendar)
            == date(2026, 1, 15, 9, 0),
            "a monthly task later this month keeps this month")

        // MARK: Interval

        let everyFifteen = task(.minutes, interval: 15)
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 12, 0),
            lastRun: date(2026, 11, 15, 11, 50), task: everyFifteen, calendar: calendar)
            == date(2026, 11, 15, 12, 5),
            "an interval task counts from its last run")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 12, 0),
            lastRun: date(2026, 11, 15, 11, 0), task: everyFifteen, calendar: calendar)
            == date(2026, 11, 15, 12, 0).addingTimeInterval(ScheduledTaskSchedule.catchUpDelay),
            "a missed interval run is caught up shortly")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 12, 0),
            lastRun: date(2026, 11, 15, 11, 0),
            task: task(.minutes, interval: 15, catchesUp: false), calendar: calendar)
            == date(2026, 11, 15, 12, 15),
            "without catch-up an interval task waits one full interval")

        // A task without a command, or switched off, has no next fire.
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 8, 0), lastRun: nil,
            task: task(.daily, command: "   "), calendar: calendar) == nil,
            "a task without a command never fires")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 8, 0), lastRun: nil,
            task: task(.daily, isEnabled: false), calendar: calendar) == nil,
            "a switched off task never fires")
        suite.expect(ScheduledTaskSchedule.nextFireDate(
            after: date(2026, 11, 15, 8, 0), lastRun: nil,
            task: task(.atLoad), calendar: calendar) == nil
            && ScheduledTaskSchedule.nextFireDate(
                after: date(2026, 11, 15, 8, 0), lastRun: nil,
                task: task(.idle), calendar: calendar) == nil,
            "at-load and idle tasks have no calendar fire date")

        // MARK: Idle

        let idleTask = task(.idle, interval: 10)
        suite.expect(ScheduledTaskSchedule.idleThreshold(for: idleTask) == 600,
                     "an idle threshold reads its interval in seconds")
        suite.expect(ScheduledTaskSchedule.idleTasksDue(
            [idleTask], idleSeconds: 599, alreadyRun: [], running: []).isEmpty,
            "an idle task waits for its threshold")
        suite.expect(ScheduledTaskSchedule.idleTasksDue(
            [idleTask], idleSeconds: 600, alreadyRun: [], running: []).count == 1,
            "an idle task fires once its threshold is met")
        suite.expect(ScheduledTaskSchedule.idleTasksDue(
            [idleTask], idleSeconds: 600, alreadyRun: [idleTask.id], running: []).isEmpty,
            "an idle task does not fire twice in one idle period")
        suite.expect(ScheduledTaskSchedule.idleTasksDue(
            [idleTask], idleSeconds: 600, alreadyRun: [], running: [idleTask.id]).isEmpty,
            "a running idle task is not started again")
        suite.expect(ScheduledTaskSchedule.idleTasksToReset(
            [idleTask], idleSeconds: 300, running: []) == [idleTask.id],
            "using the Mac again resets the idle period")
        suite.expect(ScheduledTaskSchedule.idleTasksToReset(
            [idleTask], idleSeconds: 300, running: [idleTask.id]).isEmpty,
            "a running idle task keeps its period until it finishes")

        // MARK: Shells

        let zsh = ScheduledTaskShell.zshLogin.invocation(command: "ls | wc -l")
        suite.expect(zsh.path == "/bin/zsh" && zsh.arguments == ["-lc", "ls | wc -l"],
                     "the login shell passes the whole command as one argument")
        let sh = ScheduledTaskShell.sh.invocation(command: "true")
        suite.expect(sh.path == "/bin/sh" && sh.arguments == ["-c", "true"],
                     "plain sh does not read the login profile")
        suite.expect(ScheduledTaskShell.sanitized("fish") == .zshLogin,
                     "an unknown stored shell reads as the default")

        // MARK: Stored file

        let malformed = """
        {"tasks":[{"id":"a","name":"A","command":"echo","shell":"nope",
        "schedule":{"frequency":"yearly","intervalMinutes":0,"hour":99,"minute":-3,
        "weekday":9,"dayOfMonth":40}}]}
        """
        if let decoded = try? JSONDecoder().decode(ScheduledTasksFile.self,
                                                   from: Data(malformed.utf8)) {
            let stored = decoded.tasks.first
            suite.expect(decoded.tasks.count == 1, "a hand-edited file still loads its tasks")
            suite.expect(stored?.shell == .zshLogin, "an unknown shell falls back to zsh login")
            suite.expect(stored?.schedule.frequency == .daily,
                         "an unknown frequency displays as daily")
            suite.expect(stored?.isEnabled == false,
                         "a task with an unknown frequency cannot run")
            suite.expect(stored?.schedule.intervalMinutes == 1
                    && stored?.schedule.hour == 23
                    && stored?.schedule.minute == 0
                    && stored?.schedule.weekday == 7
                    && stored?.schedule.dayOfMonth == 31,
                         "every stored schedule value is clamped on decode")
        } else {
            suite.expect(false, "a hand-edited scheduled task file decodes")
        }

        let duplicateIDs = """
        {"tasks":[{"id":"same","name":"One","command":"echo 1"},
        {"id":"same","name":"Two","command":"echo 2"}]}
        """
        if let decoded = try? JSONDecoder().decode(ScheduledTasksFile.self,
                                                   from: Data(duplicateIDs.utf8)) {
            suite.expect(decoded.tasks.count == 2
                    && Set(decoded.tasks.map(\.id)).count == 2,
                         "a duplicate stored id gets a fresh one")
        } else {
            suite.expect(false, "a file with duplicate ids decodes")
        }

        // MARK: Model round trip

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-tasks-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        let fileURL = directory.appendingPathComponent("scheduled-tasks.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ScheduledTasksModel(url: fileURL)
        let first = ScheduledTask(name: "Backup", command: "echo backup")
        model.upsert(first)
        model.upsert(ScheduledTask(name: "Second", command: "echo second"))
        model.setEnabled(false, for: first.id)
        model.recordRun(id: first.id, outcome: .succeeded, exitCode: 0,
                        at: Date(timeIntervalSince1970: 1_800_000_000))
        let reloaded = ScheduledTasksModel(url: fileURL)
        suite.expect(reloaded.tasks == model.tasks,
                     "the stored task list round trips through the model")
        suite.expect(reloaded.tasks.first(where: { $0.id == first.id })?.lastOutcome == .succeeded,
                     "the last run record survives a relaunch")
        model.remove(id: first.id)
        suite.expect(ScheduledTasksModel(url: fileURL).tasks.count == 1,
                     "removing a task is persisted")

        // MARK: Display

        let english = FeatureStrings.scheduledTasks(.enUS)
        suite.expect(ScheduledTaskSchedule.summary(for: task(.atLoad).schedule,
                                                   strings: english, calendar: calendar)
            == english.whenVorssaintStarts,
            "an at-load summary names the launch")
        suite.expect(ScheduledTaskSchedule.summary(for: task(.minutes, interval: 1).schedule,
                                                   strings: english, calendar: calendar)
            == english.everyMinute,
            "a one minute interval reads in the singular")
        suite.expect(ScheduledTaskSchedule.summary(for: task(.minutes, interval: 5).schedule,
                                                   strings: english, calendar: calendar)
            == "Every 5 minutes",
            "a longer interval names its minutes")
        suite.expect(ScheduledTaskSchedule.summary(for: task(.idle, interval: 1).schedule,
                                                   strings: english, calendar: calendar)
            == english.afterMinuteIdle,
            "a one minute idle threshold reads in the singular")
        suite.expect(ScheduledTaskSchedule.summary(for: task(.daily, hour: 9, minute: 30).schedule,
                                                   strings: english, calendar: calendar)
            .hasPrefix("Daily at "),
            "a daily summary names its time")
        suite.expect(ScheduledTaskSchedule.summary(for: task(.weekly, weekday: 2).schedule,
                                                   strings: english, calendar: calendar)
            .hasPrefix("Weekly on Monday at "),
            "a weekly summary names its weekday")
        suite.expect(ScheduledTaskSchedule.summary(for: task(.monthly, dayOfMonth: 31).schedule,
                                                   strings: english, calendar: calendar)
            .hasPrefix("Monthly on day 31 at "),
            "a monthly summary names its day without an English-only ordinal")

        // MARK: Localization

        for language in AppLanguage.allCases {
            let strings = FeatureStrings.scheduledTasks(language)
            suite.expect(!strings.title.isEmpty && !strings.hubDescription.isEmpty
                    && !strings.panelCaption.isEmpty && !strings.introCaption.isEmpty
                    && !strings.commandCaption.isEmpty && !strings.deleteMessage.isEmpty,
                         "scheduled tasks has full copy in \(language.rawValue)")
            suite.expect(strings.deleteTitleFormat.contains("%@")
                    && strings.editTaskFormat.contains("%@")
                    && strings.enableTaskFormat.contains("%@")
                    && strings.nextRunFormat.contains("%@")
                    && strings.lastRunOutcomeFormat.contains("%1$@")
                    && strings.lastRunFailedFormat.contains("%2$d")
                    && strings.everyMinutesFormat.contains("%d")
                    && strings.monthlyOnDayAtFormat.contains("%1$d")
                    && strings.weeklyOnAtFormat.contains("%2$@"),
                         "scheduled task formats keep their arguments in \(language.rawValue)")
            suite.expect(!strings.title.contains("\u{2014}")
                    && !strings.introCaption.contains("\u{2014}")
                    && !strings.introWarning.contains("\u{2014}"),
                         "scheduled task copy has no em dash in \(language.rawValue)")
            if language != .enUS {
                suite.expect(strings.title != ScheduledTasksFeatureStrings.enUS.title
                        && strings.introTitle != ScheduledTasksFeatureStrings.enUS.introTitle,
                             "scheduled tasks is translated in \(language.rawValue)")
            }
        }
    }
}
