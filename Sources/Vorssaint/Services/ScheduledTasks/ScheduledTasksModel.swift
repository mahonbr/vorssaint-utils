// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// The scheduled tasks: one source of truth for the pane, the scheduler and
/// the runner. Persists itself as JSON and tells its owner when something
/// changed.
final class ScheduledTasksModel: ObservableObject {
    static let shared = ScheduledTasksModel()

    @Published var tasks: [ScheduledTask] {
        didSet {
            guard tasks != oldValue else { return }
            persist()
            onChange?()
        }
    }

    /// Called after any change, so the scheduler re-arms with the new list.
    var onChange: (() -> Void)?

    private let url: URL?

    /// `url` is injectable so tests can point the store at a temporary file
    /// instead of the real one. A nil URL keeps the list in memory only, for
    /// a process running outside the app bundle.
    init(url: URL? = PrivateFileStore.containerURL?
        .appendingPathComponent("scheduled-tasks.json", isDirectory: false)) {
        self.url = url
        tasks = Self.load(from: url).tasks
    }

    // MARK: - Editing

    /// Adds a task or replaces the one with the same id. The editor builds a
    /// value and hands it over once, so a new task never appears half filled.
    func upsert(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    func remove(id: String) {
        tasks.removeAll { $0.id == id }
    }

    /// Switches one task without touching the others. The card's switch edits
    /// the model's copy through this, so two quick clicks cannot resurrect a
    /// stale task.
    func setEnabled(_ isOn: Bool, for id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tasks[index]
        guard updated.isEnabled != isOn else { return }
        updated.isEnabled = isOn
        tasks[index] = updated
    }

    /// Records one run in a single write, so the pane's status line and the
    /// scheduler's next fire both see the same result and the change callback
    /// fires once.
    func recordRun(id: String,
                   outcome: ScheduledTaskOutcome,
                   exitCode: Int32?,
                   at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tasks[index]
        updated.lastRun = date.timeIntervalSince1970
        updated.lastOutcome = outcome
        updated.lastExitCode = exitCode
        tasks[index] = updated
    }

    // MARK: - Persistence

    private func persist() {
        guard let url else { return }
        guard PrivateFileStore.createDirectory(at: url.deletingLastPathComponent()) else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ScheduledTasksFile(tasks: tasks)) else { return }
        PrivateFileStore.write(data, to: url)
    }

    private static func load(from url: URL?) -> ScheduledTasksFile {
        guard let url, let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(ScheduledTasksFile.self, from: data)
        else { return ScheduledTasksFile() }
        return settings
    }
}
