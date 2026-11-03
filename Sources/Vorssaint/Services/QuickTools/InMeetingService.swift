// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// The stored flag survives relaunches, so an enabled meeting mode
/// resumes on its own at the next launch. Everything here runs on the main
/// thread, where FeatureRuntime syncs.
final class InMeetingService: ObservableObject {
    static let shared = InMeetingService()

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.inMeetingEnabled)
    @Published private(set) var intervalMinutes = Defaults.sanitizedInMeetingMoveInterval(
        UserDefaults.standard.integer(forKey: DefaultsKey.inMeetingMoveInterval))

    private var timer: Timer?
    /// The delayed "move back", cancelled when the switch
    /// turns off or the next nudge starts first.
    private var pendingPointerReturn: DispatchWorkItem?

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
        intervalMinutes = Defaults.sanitizedInMeetingMoveInterval(
            UserDefaults.standard.integer(forKey: DefaultsKey.inMeetingMoveInterval))
        syncTimer()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.inMeetingEnabled)
        isEnabled = enabled
        syncTimer()
        // The switch is the feedback that it works.
        if enabled { movePointer() }
    }

    func setInterval(_ minutes: Int) {
        let minutes = Defaults.sanitizedInMeetingMoveInterval(minutes)
        guard minutes != intervalMinutes else { return }
        UserDefaults.standard.set(minutes, forKey: DefaultsKey.inMeetingMoveInterval)
        intervalMinutes = minutes
        syncTimer()
    }

    private func syncTimer() {
        guard isEnabled, AppFeature.quickToggles.isAvailable else {
            stopTimer()
            return
        }
        let interval = TimeInterval(intervalMinutes * 60)
        if timer?.timeInterval == interval { return }
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.movePointer()
        }
        timer.tolerance = min(10, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        pendingPointerReturn?.cancel()
        pendingPointerReturn = nil
    }

    /// The return move only fires if the pointer
    /// still sits where the nudge left it, so it never fights the user.
    private func movePointer() {
        guard isEnabled,
              let original = Self.currentPointerLocation(),
              let target = Self.moveTarget(from: original),
              Self.postPointerMove(to: target) else { return }

        pendingPointerReturn?.cancel()
        let returnMove = DispatchWorkItem { [weak self] in
            self?.pendingPointerReturn = nil
            guard let current = Self.currentPointerLocation(),
                  abs(current.x - target.x) <= 2,
                  abs(current.y - target.y) <= 2 else { return }
            _ = Self.postPointerMove(to: original)
        }
        pendingPointerReturn = returnMove
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: returnMove)
    }

    private static func currentPointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// The pixel next to `original` that stays inside its display's bounds,
    /// preferring a step to the right.
    private static func moveTarget(from original: CGPoint) -> CGPoint? {
        guard let bounds = displayBounds(containing: original) else { return nil }
        let safeFrame = bounds.insetBy(dx: 2, dy: 2)
        let x = min(max(original.x, safeFrame.minX), safeFrame.maxX)
        let y = min(max(original.y, safeFrame.minY), safeFrame.maxY)

        if x + 1 <= safeFrame.maxX { return CGPoint(x: x + 1, y: y) }
        if x - 1 >= safeFrame.minX { return CGPoint(x: x - 1, y: y) }
        if y + 1 <= safeFrame.maxY { return CGPoint(x: x, y: y + 1) }
        if y - 1 >= safeFrame.minY { return CGPoint(x: x, y: y - 1) }
        return nil
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }

        for display in displays.prefix(Int(count)) {
            let bounds = CGDisplayBounds(display)
            if point.x >= bounds.minX, point.x <= bounds.maxX,
               point.y >= bounds.minY, point.y <= bounds.maxY {
                return bounds
            }
        }
        return nil
    }

    private static func postPointerMove(to point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}
