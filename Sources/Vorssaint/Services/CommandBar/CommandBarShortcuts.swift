// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// The Mac's own Shortcuts, as rows.
///
/// `shortcuts list` is the only inventory that asks for nothing first: it
/// names local and iCloud-synced shortcuts alike, while the files macOS keeps
/// under ~/Library/Shortcuts sit behind Full Disk Access and can lag the
/// app's own list. Running goes through the same tool, so a shortcut never
/// has to be added to the Dock or opened in the editor to fire.
///
/// Not part of the pure-function test harness (`./build.sh --test`): both
/// directions are a call into the system's tool and nothing else.
enum CommandBarShortcuts {
    /// The Shortcuts app's own icon, for the rows to wear when macOS ships it.
    static let applicationIconPath: String? =
        FileManager.default.fileExists(atPath: "/System/Applications/Shortcuts.app")
            ? "/System/Applications/Shortcuts.app" : nil

    /// Runners kept alive until they exit. A `Process` with no strong
    /// reference left can be deallocated mid-run, so each one is held by pid
    /// for exactly as long as it runs; a shortcut that never ends keeps one
    /// entry in a dictionary and nothing else.
    private static var running: [pid_t: Process] = [:]
    private static let runningLock = NSLock()

    /// Every shortcut the system knows, one name per line from its own tool.
    /// Sorted here so the catalog and the browse category see one stable order.
    static func installed() -> [String] {
        let result = Shell.run("/usr/bin/shortcuts", ["list"], timeout: 15)
        guard result.status == 0 else { return [] }
        var seen = Set<String>()
        return result.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Asks the system's runner to take the shortcut and lets it finish on
    /// its own. Waiting is the trap: `entry.run` is answered on the main
    /// thread, and a shortcut that takes a minute would hold it. A nonzero
    /// exit still answers with a beep, because the bar that launched the run
    /// is already gone.
    static func run(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        // A shortcut that reads stdin would hang forever on an inherited
        // handle nobody writes to; interactive prompts surface through the
        // system's own UI instead.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            runningLock.withLock { _ = running.removeValue(forKey: finished.processIdentifier) }
            if finished.terminationReason == .exit, finished.terminationStatus != 0 {
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
        do {
            try process.run()
            runningLock.withLock {
                if process.isRunning { running[process.processIdentifier] = process }
            }
        } catch {
            NSSound.beep()
        }
    }
}
