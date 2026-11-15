// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// When a scheduled task runs. The raw values are what a stored file names, so
/// renaming a case cannot silently move a task to another schedule.
enum ScheduledTaskFrequency: String, Codable, CaseIterable, Identifiable {
    case atLoad = "at-load"
    case minutes
    /// Once the Mac has had no keyboard or mouse input for a while.
    case idle
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    func title(_ strings: ScheduledTasksFeatureStrings) -> String {
        switch self {
        case .atLoad: strings.frequencyAtLoad
        case .minutes: strings.frequencyMinutes
        case .idle: strings.frequencyIdle
        case .daily: strings.frequencyDaily
        case .weekly: strings.frequencyWeekly
        case .monthly: strings.frequencyMonthly
        }
    }
}

/// The shell a task runs in. The command is passed as one argument, so quotes,
/// pipes and redirections behave the way they do in a terminal.
enum ScheduledTaskShell: String, Codable, CaseIterable, Identifiable {
    case zshLogin = "zsh-login"
    case sh
    case userShell = "user-shell"

    var id: String { rawValue }

    func title(_ strings: ScheduledTasksFeatureStrings) -> String {
        switch self {
        case .zshLogin: strings.shellZshLogin
        case .sh: strings.shellSh
        case .userShell: strings.shellUserShell
        }
    }

    /// A stored value this version does not know reads as the default rather
    /// than as a shell that may not exist.
    static func sanitized(_ raw: String) -> ScheduledTaskShell {
        ScheduledTaskShell(rawValue: raw) ?? .zshLogin
    }

    /// The executable and arguments for one command. A login shell is what
    /// puts Homebrew and other profile-installed tools on PATH; plain sh is
    /// offered for tasks that do not want the profile.
    func invocation(command: String) -> (path: String, arguments: [String]) {
        switch self {
        case .zshLogin:
            return ("/bin/zsh", ["-lc", command])
        case .sh:
            return ("/bin/sh", ["-c", command])
        case .userShell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
            let path = shell.hasPrefix("/")
                && FileManager.default.isExecutableFile(atPath: shell)
                ? shell
                : "/bin/zsh"
            return (path, ["-lc", command])
        }
    }
}

/// When a task runs, as stored. Every value is clamped on decode, so a
/// hand-edited file cannot arm a time the calendar cannot represent.
struct ScheduledTaskScheduleSettings: Codable, Equatable {
    var frequency: ScheduledTaskFrequency = .daily
    /// Read by `.minutes` and `.idle`.
    var intervalMinutes = 30
    /// The wall-clock hour and minute the person picked, 0-23 and 0-59.
    var hour = 9
    var minute = 0
    /// 1 = Sunday ... 7 = Saturday, only read by `.weekly`.
    var weekday = 2
    /// 1...31, only read by `.monthly`. A short month clamps to its last day.
    var dayOfMonth = 1

    enum CodingKeys: String, CodingKey {
        case frequency, intervalMinutes, hour, minute, weekday, dayOfMonth
    }

    init() {}

    /// A key added after the first release has no value in an older file, so
    /// it falls back to its own default. A frequency this version does not
    /// know reads as daily for display; the task itself is switched off by
    /// `ScheduledTask.init(from:)` so it cannot run unexpectedly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawFrequency = try container.decodeIfPresent(String.self, forKey: .frequency)
            ?? ScheduledTaskFrequency.daily.rawValue
        frequency = ScheduledTaskFrequency(rawValue: rawFrequency) ?? .daily
        intervalMinutes = Self.clampedInterval(
            try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30)
        hour = min(max(try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9, 0), 23)
        minute = min(max(try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0, 0), 59)
        weekday = min(max(try container.decodeIfPresent(Int.self, forKey: .weekday) ?? 2, 1), 7)
        dayOfMonth = min(max(
            try container.decodeIfPresent(Int.self, forKey: .dayOfMonth) ?? 1, 1), 31)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency.rawValue, forKey: .frequency)
        try container.encode(intervalMinutes, forKey: .intervalMinutes)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(weekday, forKey: .weekday)
        try container.encode(dayOfMonth, forKey: .dayOfMonth)
    }

    static let intervalRange = 1...1440

    static func clampedInterval(_ value: Int) -> Int {
        min(max(value, intervalRange.lowerBound), intervalRange.upperBound)
    }
}

/// What happened the last time a task ran.
enum ScheduledTaskOutcome: String, Codable, Equatable {
    case succeeded, failed, stopped, couldNotStart

    func title(_ strings: ScheduledTasksFeatureStrings) -> String {
        switch self {
        case .succeeded: strings.outcomeSucceeded
        case .failed: strings.outcomeFailed
        case .stopped: strings.outcomeStopped
        case .couldNotStart: strings.outcomeCouldNotStart
        }
    }
}

/// One scheduled command. Its id is stable across edits, so the scheduler and
/// the pane can talk about the same task while its name and schedule change.
struct ScheduledTask: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var command: String
    var shell: ScheduledTaskShell = .zshLogin
    var schedule = ScheduledTaskScheduleSettings()
    /// Whether a run missed while Vorssaint was closed or the Mac was asleep
    /// fires once shortly after launch or wake. At-load tasks ignore this:
    /// they run once per launch either way.
    var catchesUp = true
    var isEnabled = true
    /// Epoch seconds, zero until the first run.
    var lastRun: Double = 0
    var lastOutcome: ScheduledTaskOutcome?
    var lastExitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case id, name, command, shell, schedule, catchesUp, isEnabled,
             lastRun, lastOutcome, lastExitCode
    }

    init(id: String = UUID().uuidString,
         name: String = "",
         command: String = "",
         shell: ScheduledTaskShell = .zshLogin,
         schedule: ScheduledTaskScheduleSettings = ScheduledTaskScheduleSettings(),
         catchesUp: Bool = true,
         isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.shell = shell
        self.schedule = schedule
        self.catchesUp = catchesUp
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        shell = ScheduledTaskShell.sanitized(
            try container.decodeIfPresent(String.self, forKey: .shell)
                ?? ScheduledTaskShell.zshLogin.rawValue)
        schedule = try container.decodeIfPresent(ScheduledTaskScheduleSettings.self,
                                                 forKey: .schedule)
            ?? ScheduledTaskScheduleSettings()
        catchesUp = try container.decodeIfPresent(Bool.self, forKey: .catchesUp) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastRun = max(try container.decodeIfPresent(Double.self, forKey: .lastRun) ?? 0, 0)
        // The run record is decoration: a hand-edited or older value must not
        // take the whole task list down with it.
        lastOutcome = try? container.decode(ScheduledTaskOutcome.self, forKey: .lastOutcome)
        lastExitCode = try? container.decode(Int32.self, forKey: .lastExitCode)

        // A frequency this version does not know must not arm a command. The
        // schedule falls back to daily for display, and the task stays off
        // until the person picks a schedule it understands.
        if let nested = try? container.nestedContainer(
            keyedBy: ScheduledTaskScheduleSettings.CodingKeys.self, forKey: .schedule),
           let raw = try? nested.decode(String.self, forKey: .frequency),
           ScheduledTaskFrequency(rawValue: raw) == nil {
            isEnabled = false
        }
    }

    /// The name the pane and any alert show. A blank name is a task, not a
    /// reason to leave an empty row.
    func displayName(_ strings: ScheduledTasksFeatureStrings) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? strings.untitledTask : trimmed
    }

    /// A task without a command has nothing to run. It stays in the list so
    /// its schedule is not lost, but the scheduler and the Run Now button
    /// leave it alone.
    var isRunnable: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var lastRunDate: Date? {
        lastRun > 0 ? Date(timeIntervalSince1970: lastRun) : nil
    }

    /// Returns this task with `current`'s run record. The editor never edits
    /// the record, so saving a snapshot taken before a run finished must not
    /// erase that run.
    func preservingRunRecord(from current: ScheduledTask) -> ScheduledTask {
        var merged = self
        merged.lastRun = current.lastRun
        merged.lastOutcome = current.lastOutcome
        merged.lastExitCode = current.lastExitCode
        return merged
    }
}

/// The whole file: the tasks in the order the person added them. A duplicate
/// id would let the scheduler run one task while the pane edits another, so
/// later duplicates get a fresh id on decode.
struct ScheduledTasksFile: Codable, Equatable {
    var tasks: [ScheduledTask] = []

    enum CodingKeys: String, CodingKey {
        case tasks
    }

    init() {}

    init(tasks: [ScheduledTask]) {
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decoded = try container.decodeIfPresent([ScheduledTask].self, forKey: .tasks) ?? []
        var seen = Set<String>()
        for index in decoded.indices where !seen.insert(decoded[index].id).inserted {
            decoded[index].id = UUID().uuidString
        }
        tasks = decoded
    }
}
