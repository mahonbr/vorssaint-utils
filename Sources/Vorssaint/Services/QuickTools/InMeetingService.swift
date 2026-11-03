// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import IOKit.pwr_mgt
import os

/// The stored flag survives relaunches, so an enabled meeting mode
/// resumes on its own at the next launch. Everything here runs on the main
/// thread, where FeatureRuntime syncs.
final class InMeetingService: ObservableObject {
    static let shared = InMeetingService()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                    category: "in-meeting")

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.inMeetingEnabled)

    /// Held while the feature is on; released by power management only
    /// if the app dies, so they never outlive the switch.
    private var systemAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var displayAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    private init() {}

    /// The stored menu bar symbol name, or empty for the Vorssaint mark.
    static var storedSymbol: String {
        Defaults.sanitizedMenuBarIconSymbol(
            UserDefaults.standard.string(forKey: DefaultsKey.inMeetingMenuBarSymbol))
    }

    static var storedOpacity: Double {
        Defaults.sanitizedInMeetingIconOpacity(
            UserDefaults.standard.double(forKey: DefaultsKey.inMeetingIconOpacity))
    }

    /// Whether the menu bar icon must stay visible while the switch is on,
    /// even when the metrics options would hide the glyph: the state only
    /// reads when the icon actually looks different.
    var signalsActiveIcon: Bool {
        isEnabled && (InMeetingIconTint.current != .none || !Self.storedSymbol.isEmpty)
    }

    /// Re-reads the stored switches and the feature gate; the binding runs it
    /// at launch and again whenever the feature is installed or removed, so
    /// an uninstall stops nudging on the spot without touching the flags.
    func syncWithPreferences() {
        isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.inMeetingEnabled)
        syncAssertions()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.inMeetingEnabled)
        isEnabled = enabled
        syncAssertions()
    }

    /// Synthetic input does not reliably reset the power-management idle
    /// timers, so the keep-awake is a pair of held assertions — the same
    /// mechanism `caffeinate` uses. Held for the whole toggle, no timer.
    private func syncAssertions() {
        guard isEnabled, AppFeature.quickToggles.isAvailable else {
            releaseAssertions()
            return
        }
        holdAssertion("PreventUserIdleDisplaySleep", into: &displayAssertion)
        holdAssertion("PreventUserIdleSystemSleep", into: &systemAssertion)
    }

    private func holdAssertion(_ type: String, into slot: inout IOPMAssertionID) {
        guard slot == IOPMAssertionID(kIOPMNullAssertionID) else { return }
        var assertion = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "In a meeting" as CFString,
            &assertion)
        guard result == kIOReturnSuccess else {
            Self.log.error("\(type) failed: \(result)")
            return
        }
        slot = assertion
    }

    private func releaseAssertions() {
        for assertion in [systemAssertion, displayAssertion] where assertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(assertion)
        }
        systemAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        displayAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    }
}
