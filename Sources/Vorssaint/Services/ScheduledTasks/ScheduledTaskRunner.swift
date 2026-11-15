// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Darwin
import Foundation

/// Runs one task at a time per id. Output is discarded on purpose: this
/// feature reports the outcome, not the transcript, and a discarded stream
/// cannot fill and block the child.
final class ScheduledTaskRunner: ObservableObject {
    static let shared = ScheduledTaskRunner()

    @Published private(set) var runningTaskIDs: Set<String> = []

    private var processes: [String: Process] = [:]
    private var stoppedIDs: Set<String> = []

    init() {}

    /// Starts `task` unless it is already running. The completion runs on the
    /// main queue with the outcome and, when there was one, the exit status.
    @discardableResult
    func start(_ task: ScheduledTask,
               completion: @escaping (ScheduledTaskOutcome, Int32?) -> Void) -> Bool {
        guard !runningTaskIDs.contains(task.id) else { return false }
        let command = task.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return false }

        let invocation = task.shell.invocation(command: command)
        guard FileManager.default.isExecutableFile(atPath: invocation.path) else {
            completion(.couldNotStart, nil)
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.path)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // A scheduled command has nobody to answer a prompt, so stdin is
        // closed. Output is not part of this feature; discarding it keeps the
        // child from blocking on a stream nobody drains.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes[task.id] = nil
                self.runningTaskIDs.remove(task.id)
                if self.stoppedIDs.remove(task.id) != nil {
                    completion(.stopped, nil)
                } else {
                    completion(finished.terminationStatus == 0 ? .succeeded : .failed,
                               finished.terminationStatus)
                }
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            completion(.couldNotStart, nil)
            return false
        }
        processes[task.id] = process
        runningTaskIDs.insert(task.id)
        return true
    }

    /// Asks a running task to stop, then insists after two seconds. The
    /// termination handler reports `.stopped`, so the pane never reads a
    /// deliberate stop as a failure.
    func stop(id: String) {
        guard let process = processes[id], process.isRunning else { return }
        stoppedIDs.insert(id)
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func stopAll() {
        for id in Array(processes.keys) {
            stop(id: id)
        }
    }

    func isRunning(_ id: String) -> Bool {
        runningTaskIDs.contains(id)
    }
}
