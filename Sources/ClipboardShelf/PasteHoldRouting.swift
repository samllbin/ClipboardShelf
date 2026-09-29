import Carbon
import CoreGraphics
import Foundation

/// Pure routing for a short Command-V tap versus a held Command-V gesture.
/// The caller schedules the deadline and performs the returned actions in order.
/// No application state or clipboard contents are accessed here.
struct PasteHoldRouting {
    enum Phase { case down, up, flagsChanged }
    enum Action: Equatable {
        case passThrough, suppress, beginHold, pasteCurrent, showCandidates, cancel
    }

    struct Event {
        var phase: Phase
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        var isRepeat = false
        var isSynthetic = false
        var timestamp: TimeInterval
    }

    static let threshold: TimeInterval = 0.4

    private var pendingSince: TimeInterval?
    private var hasSuppressedEscape = false
    private(set) var hasSuppressedV = false
    var isPending: Bool { pendingSince != nil }
    var isTracking: Bool { isPending || hasSuppressedV || hasSuppressedEscape }

    mutating func route(_ event: Event, canIntercept: Bool) -> [Action] {
        // Marked paste events must not consume the physical key's eventual up.
        guard !event.isSynthetic else { return [.passThrough] }
        guard canIntercept else {
            reset()
            return [.passThrough]
        }

        if event.keyCode == CGKeyCode(kVK_Escape), hasSuppressedEscape {
            if event.phase == .up {
                hasSuppressedEscape = false
                return [.suppress]
            }
            if event.phase == .down { return [.suppress] }
        }

        if event.phase == .flagsChanged {
            guard isPending, !Self.isCommandOnly(event.flags) else { return [.passThrough] }
            // Releasing Command or starting a different shortcut ends the hold.
            // A delayed timer must still recognize a gesture held to its deadline.
            return [finishPending(at: event.timestamp), .passThrough]
        }

        if event.keyCode == CGKeyCode(kVK_ANSI_V) {
            if event.phase == .up {
                guard hasSuppressedV else { return [.passThrough] }
                hasSuppressedV = false
                return isPending ? [finishPending(at: event.timestamp), .suppress] : [.suppress]
            }

            if event.isRepeat {
                guard hasSuppressedV else { return [.passThrough] }
                if isPending, !Self.isCommandOnly(event.flags) {
                    return [finishPending(at: event.timestamp), .suppress]
                }
                return advance(to: event.timestamp, canIntercept: true) + [.suppress]
            }

            // A new nonrepeat down denotes a new physical press. Recover from a
            // missing old key-up without swallowing subsequent ordinary typing.
            pendingSince = nil
            hasSuppressedV = false
            guard Self.isCommandOnly(event.flags) else { return [.passThrough] }
            pendingSince = event.timestamp
            hasSuppressedV = true
            return [.beginHold, .suppress]
        }

        // Other key releases do not end the V gesture. A following key press
        // commits a quick paste first so it cannot overtake the captured shortcut.
        guard event.phase == .down, isPending else { return [.passThrough] }
        pendingSince = nil
        if event.keyCode == CGKeyCode(kVK_Escape) {
            hasSuppressedEscape = true
            return [.cancel, .suppress]
        }
        return [.pasteCurrent, .passThrough]
    }

    mutating func advance(to time: TimeInterval, canIntercept: Bool) -> [Action] {
        guard canIntercept else {
            reset()
            return []
        }
        guard let pendingSince, time >= pendingSince + Self.threshold else { return [] }
        self.pendingSince = nil
        return [.showCandidates]
    }

    /// Abandon an unsafe hold (for example, after a target focus change) while
    /// retaining key pairing so the captured physical V never leaks into typing.
    @discardableResult
    mutating func cancelPending() -> [Action] {
        pendingSince = nil
        return []
    }

    mutating func reset() {
        pendingSince = nil
        hasSuppressedV = false
        hasSuppressedEscape = false
    }

    private mutating func finishPending(at time: TimeInterval) -> Action {
        let isLongPress = pendingSince.map { time >= $0 + Self.threshold } ?? false
        pendingSince = nil
        return isLongPress ? .showCandidates : .pasteCurrent
    }

    private static func isCommandOnly(_ flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift,
            .maskAlphaShift, .maskSecondaryFn, .maskHelp, .maskNumericPad
        ]
        return flags.intersection(modifiers).subtracting(.maskAlphaShift) == .maskCommand
    }
}
