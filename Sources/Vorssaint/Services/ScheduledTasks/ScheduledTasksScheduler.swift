// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Arms one timer at the earliest due task and re-arms after every run or
/// settings change. Idle tasks get a second, repeating timer that checks how
/// long the Mac has been quiet. Nothing exists while the feature is off: no
/// timer, no observers, no process.
final class ScheduledTasksScheduler: ObservableObject {
    static let shared = ScheduledTasksScheduler()

    /// How often an idle task's threshold is checked. The timer exists only
    /// while at least one enabled idle task does.
    private static let defaultIdlePollInterval: TimeInterval = 10

    /// Seconds since the last keyboard, mouse or tablet input in this session.
    /// `kCGAnyInputEventType` is the sentinel that means "any input"; Swift
    /// does not expose it as a `CGEventType` case.
    private static let systemIdleTime: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// The next fire per task, for the pane's status line.
    @Published private(set) var nextFire: [String: Date] = [:]

    private var timer: Timer?
    private var idleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var clockObservers: [NSObjectProtocol] = []
    private var isEnabled = false
    private var started = false
    private var atLoadFire: Date?
    private var didRunAtLoad: Set<String> = []
    private var idleFired: Set<String> = []

    private let runner: ScheduledTaskRunner
    private let model: ScheduledTasksModel
    private let idleTime: () -> TimeInterval
    private let idlePollInterval: TimeInterval

    init(runner: ScheduledTaskRunner = .shared,
         model: ScheduledTasksModel = .shared,
         idleTime: @escaping () -> TimeInterval = ScheduledTasksScheduler.systemIdleTime,
         idlePollInterval: TimeInterval = ScheduledTasksScheduler.defaultIdlePollInterval) {
        self.runner = runner
        self.model = model
        self.idleTime = idleTime
        self.idlePollInterval = idlePollInterval
        model.onChange = { [weak self] in self?.arm() }
    }

    /// Re-reads the feature gate and the stored tasks. Called at launch and
    /// after any change, so an off switch stops the timer on the spot.
    func syncWithPreferences() {
        sync(enabled: AppFeature.scheduledTasks.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.scheduledTasksEnabled))
    }

    /// Re-reads the feature gate and the stored tasks. Called at launch and
    /// after any change, so an off switch stops the timer on the spot.
    func sync(enabled: Bool) {
        isEnabled = enabled
        guard enabled else {
            stop(terminateRunning: true)
            return
        }
        if !started {
            started = true
            atLoadFire = Date().addingTimeInterval(ScheduledTaskSchedule.atLoadDelay)
        }
        installObservers()
        arm()
    }

    /// Stops the timer and observers. `terminateRunning` is for the feature
    /// switch and app termination; a settings change while on leaves a task
    /// that is already running alone.
    func stop(terminateRunning: Bool) {
        isEnabled = false
        timer?.invalidate()
        timer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if !idleFired.isEmpty { idleFired = [] }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers = []
        if !nextFire.isEmpty { nextFire = [:] }
        if terminateRunning { runner.stopAll() }
    }

    // MARK: - Arming

    private func installObservers() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            // A fire date that passed during sleep never triggers its timer;
            // recomputing catches the miss shortly after wake.
            self?.arm()
        }
        // The chosen time means the person's wall clock: when the time zone or
        // the system clock changes, the armed fire date is stale.
        clockObservers = [NSNotification.Name.NSSystemTimeZoneDidChange,
                          NSNotification.Name.NSSystemClockDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil,
                                                   queue: .main) { [weak self] _ in
                self?.arm()
            }
        }
    }

    private func arm() {
        guard isEnabled else { return }
        timer?.invalidate()
        timer = nil

        let now = Date()
        var next: [String: Date] = [:]
        for task in model.tasks
        where task.isEnabled && task.isRunnable && !runner.isRunning(task.id) {
            if task.schedule.frequency == .atLoad {
                if let atLoadFire, !didRunAtLoad.contains(task.id) {
                    next[task.id] = max(atLoadFire, now)
                }
            } else if let fire = ScheduledTaskSchedule.nextFireDate(
                after: now, lastRun: task.lastRunDate, task: task) {
                next[task.id] = fire
            }
        }
        if nextFire != next { nextFire = next }
        syncIdleTimer()

        // The at-load phase needs a timer even when no at-load task is due, so
        // it can close: a task added after launch must wait for the next launch.
        var earliest = next.values.min()
        if let atLoadFire {
            earliest = min(earliest ?? atLoadFire, atLoadFire)
        }
        guard let earliest else { return }

        let timer = Timer(fire: earliest, interval: 0, repeats: false) { [weak self] _ in
            self?.fire()
        }
        // Tight tolerance: one shot costs nothing, and a schedule that fires a
        // minute late reads as broken to anyone testing it.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - One fire

    private func fire() {
        timer = nil
        let now = Date()

        // At-load tasks are a launch phase, not a repeating schedule: run the
        // enabled ones once, then forget the phase so a task added later waits
        // for the next launch.
        if let atLoadFire, now >= atLoadFire {
            for task in model.tasks
            where task.schedule.frequency == .atLoad && task.isEnabled
                && task.isRunnable && !didRunAtLoad.contains(task.id) {
                didRunAtLoad.insert(task.id)
                run(task)
            }
            self.atLoadFire = nil
        }

        for (id, fireDate) in nextFire where fireDate <= now {
            guard let task = model.tasks.first(where: { $0.id == id }),
                  task.isEnabled, task.isRunnable,
                  task.schedule.frequency != .atLoad,
                  task.schedule.frequency != .idle,
                  !runner.isRunning(id)
            else { continue }
            run(task)
        }

        arm()
    }

    // MARK: - Idle

    private func syncIdleTimer() {
        let idleTasks = model.tasks.filter {
            $0.schedule.frequency == .idle && $0.isEnabled && $0.isRunnable
        }
        guard !idleTasks.isEmpty else {
            idleTimer?.invalidate()
            idleTimer = nil
            if !idleFired.isEmpty { idleFired = [] }
            return
        }
        // Drop ids for tasks that were deleted or no longer use the idle
        // schedule. A disabled task comes back as a fresh idle period.
        let liveIDs = Set(idleTasks.map(\.id))
        if !idleFired.isSubset(of: liveIDs) { idleFired.formIntersection(liveIDs) }
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: idlePollInterval, repeats: true) { [weak self] _ in
            self?.checkIdleTasks()
        }
        timer.tolerance = min(2, idlePollInterval / 2)
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdleTasks() {
        guard isEnabled else { return }
        let idleTasks = model.tasks.filter { $0.schedule.frequency == .idle }
        let running = runner.runningTaskIDs
        let idleSeconds = idleTime()
        let reset = ScheduledTaskSchedule.idleTasksToReset(idleTasks,
                                                           idleSeconds: idleSeconds,
                                                           running: running)
        if !reset.isEmpty { idleFired.subtract(reset) }
        for task in ScheduledTaskSchedule.idleTasksDue(idleTasks,
                                                       idleSeconds: idleSeconds,
                                                       alreadyRun: idleFired,
                                                       running: running) {
            idleFired.insert(task.id)
            run(task)
        }
    }

    private func run(_ task: ScheduledTask) {
        runner.start(task) { [weak self] outcome, exitCode in
            guard let self else { return }
            self.model.recordRun(id: task.id, outcome: outcome, exitCode: exitCode)
            self.arm()
        }
    }
}
