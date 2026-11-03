// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// A short chime at the top of every hour, the one quick toggle that is a
/// standing switch rather than a one-click action. The timer lives only while
/// the switch is on and the feature is installed; the stored flag survives
/// relaunches, so an enabled beep resumes on its own at the next launch.
/// Everything here runs on the main thread, where FeatureRuntime syncs.
final class HourlyBeepService: ObservableObject {
    static let shared = HourlyBeepService()

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.hourlyBeepEnabled)

    /// One timer at a time, always aiming at the next top of the hour.
    private var timer: Timer?

    /// The registered alert sound for the stored choice, rebuilt only when
    /// the name it resolves to changes, so hourly replays cost nothing.
    private var armedSound: AlertSound?
    private var armedSoundName = ""

    private init() {}

    /// The stored picker's choice resolved against the sounds this Mac
    /// actually ships: a name saved on another Mac, or one a macOS update
    /// dropped, still chimes rather than going silent.
    private static func preferredSoundName() -> String? {
        TextSnippetSupport.resolvedSoundName(
            stored: UserDefaults.standard.string(forKey: DefaultsKey.hourlyBeepSound),
            fallback: Defaults.defaultHourlyBeepSoundName)
    }

    /// Plays what the next chime would play, for the picker's preview.
    func previewSound() {
        chime()?.play()
    }

    /// The armed sound for the current stored choice, resolving it fresh so
    /// the preview and the chime can never disagree about which name wins.
    private func chime() -> AlertSound? {
        guard let name = Self.preferredSoundName() else { return nil }
        if name != armedSoundName || armedSound == nil {
            armedSound = AlertSound(name: name)
            armedSoundName = armedSound == nil ? "" : name
        }
        return armedSound
    }

    /// Re-reads the stored switch and the feature gate; the binding runs it
    /// at launch and again whenever the feature is installed or removed, so
    /// an uninstall silences the chime on the spot without touching the flag.
    func syncWithPreferences() {
        isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.hourlyBeepEnabled)
        syncTimer()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.hourlyBeepEnabled)
        isEnabled = enabled
        syncTimer()
    }

    private func syncTimer() {
        if isEnabled, AppFeature.quickToggles.isAvailable {
            scheduleNext()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// One shot per chime, re-aimed after every ring: a repeating timer would
    /// slowly drift off the hour, and recomputing costs nothing. Scheduled in
    /// the common modes so a chime is not skipped while a menu stays tracked.
    private func scheduleNext() {
        timer?.invalidate()
        let now = Date()
        let next = Calendar.current.dateInterval(of: .hour, for: now)?.end
            ?? now.addingTimeInterval(3600)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.ring(due: next)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// How far past the top of the hour a fire still counts as on time.
    /// Run-loop tracking delays a chime by seconds at most; anything later
    /// is a timer the system held while the Mac was asleep.
    private static let lateTolerance: TimeInterval = 30

    /// A chime is only worth playing while it still means "the top of the
    /// hour": a Mac asleep at the moment fires its overdue timer on wake,
    /// and a beep for an hour that already passed is noise, not a chime.
    private func ring(due: Date) {
        timer = nil
        if Date().timeIntervalSince(due) <= Self.lateTolerance {
            if let chime = chime() {
                chime.play()
            } else {
                NSSound.beep()
            }
        }
        syncTimer()
    }
}
