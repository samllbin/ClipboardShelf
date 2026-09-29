import AppKit
import ApplicationServices
import Carbon

/// A short chord replays native paste at release. A held chord opens the picker
/// without inserting anything first. No clipboard contents are read here.
@MainActor
final class PasteTrigger {
    var canBeginHold: (() -> Bool)?
    var onTrigger: ((pid_t, Int) -> Bool)?
    var onGestureCancelled: (() -> Void)?
    var onUnavailable: ((String) -> Void)?
    static let syntheticMarker: Int64 = 0x4353484650415354

    private struct HoldContext {
        let targetPID: pid_t
        let clipboardVersion: Int
        let generation: UUID
    }
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var routing = PasteHoldRouting()
    private var context: HoldContext?
    private var holdTimer: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var lastUnavailableMessage: String?

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            stop()
            reportUnavailable("请在系统设置的「隐私与安全性 → 辅助功能」中允许拾光剪贴板，以启用长按候选栏。")
            return false
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if isRunning { return true }
            // A stale tap cannot recover by enabling it repeatedly; rebuild it.
            stop()
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<PasteTrigger>.fromOpaque(context).takeUnretainedValue().handle(type: type, event: event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            reportUnavailable("无法启用长按候选栏，请检查辅助功能权限；普通粘贴仍可使用。")
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard isRunning else { stop(); return false }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let context = self.context,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.processIdentifier != context.targetPID { self.cancelGesture() }
            }
        }
        lastUnavailableMessage = nil
        return true
    }

    func stop() {
        cancelGesture()
        routing.reset()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        runLoopSource = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Confirms dispatch, not whether the target application accepted the paste.
    static func postPaste(to pid: pid_t) -> Bool {
        guard pid > 0, let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.postToPid(pid)
        }
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelGesture()
            routing.reset()
            if AXIsProcessTrusted(), let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            else { stop(); reportUnavailable("辅助功能权限已关闭，⌘V 已恢复普通粘贴。") }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return Unmanaged.passUnretained(event) }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            cancelGesture()
            return Unmanaged.passUnretained(event)
        }
        guard [.keyDown, .keyUp, .flagsChanged].contains(type) else { return Unmanaged.passUnretained(event) }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown && keyCode != CGKeyCode(kVK_ANSI_V) && !routing.isPending { onGestureCancelled?() }
        guard routing.isTracking || (type == .keyDown && keyCode == CGKeyCode(kVK_ANSI_V)) else { return Unmanaged.passUnretained(event) }
        guard AXIsProcessTrusted() else {
            stop()
            reportUnavailable("辅助功能权限已关闭，⌘V 已恢复普通粘贴。")
            return Unmanaged.passUnretained(event)
        }
        let available = !IsSecureEventInputEnabled()
        if !available { cancelGesture() }
        if let context, !contextIsValid(context) { cancelGesture() }
        let ownsChord = routing.isTracking
        let canStart = available && (ownsChord || canBeginHold?() == true)
        let actions = routing.route(.init(
            phase: type == .keyDown ? .down : type == .keyUp ? .up : .flagsChanged,
            keyCode: keyCode, flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            timestamp: Double(event.timestamp) / 1_000_000_000
        ), canIntercept: canStart)
        var suppress = false
        for action in actions {
            switch action {
            case .passThrough: break
            case .suppress: suppress = true
            case .beginHold:
                beginHold()
            case .pasteCurrent:
                finishShortPress()
            case .showCandidates:
                finishLongPress()
            case .cancel:
                cancelGesture()
            }
        }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func beginHold() {
        holdTimer?.cancel()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { cancelGesture(); return }
        let context = HoldContext(targetPID: app.processIdentifier,
                                  clipboardVersion: NSPasteboard.general.changeCount, generation: UUID())
        self.context = context
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.context?.generation == context.generation, self.routing.isPending else { return }
            guard self.contextIsValid(context), self.canBeginHold?() == true else { self.cancelGesture(); return }
            // If release is already physically complete, its queued event decides
            // short versus long using its timestamp, avoiding a late timer popup.
            let physicalFlags = CGEventSource.flagsState(.hidSystemState)
            guard CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_ANSI_V)),
                  physicalFlags.contains(.maskCommand) else { return }
            guard physicalFlags.intersection([.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty else { return }
            let actions = self.routing.advance(to: ProcessInfo.processInfo.systemUptime, canIntercept: true)
            if actions.contains(.showCandidates) { self.finishLongPress() }
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteHoldRouting.threshold, execute: work)
    }

    private func finishShortPress() {
        holdTimer?.cancel()
        holdTimer = nil
        guard let context else { return }
        self.context = nil
        guard contextIsValid(context) else { return }
        // Synchronous dispatch preserves ordering before an immediately following
        // user key. The synthetic marker prevents this replay from starting a hold.
        _ = Self.postPaste(to: context.targetPID)
    }

    private func finishLongPress() {
        holdTimer?.cancel()
        holdTimer = nil
        guard let context else { return }
        self.context = nil
        guard contextIsValid(context), canBeginHold?() == true else { return }
        _ = onTrigger?(context.targetPID, context.clipboardVersion)
    }

    private func contextIsValid(_ context: HoldContext) -> Bool {
        AXIsProcessTrusted() && !IsSecureEventInputEnabled()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == context.targetPID
            && NSPasteboard.general.changeCount == context.clipboardVersion
    }

    private func cancelGesture() {
        holdTimer?.cancel()
        holdTimer = nil
        context = nil
        routing.cancelPending()
        onGestureCancelled?()
    }

    private func reportUnavailable(_ message: String) {
        guard message != lastUnavailableMessage else { return }
        lastUnavailableMessage = message
        onUnavailable?(message)
    }

    deinit {
        holdTimer?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }
}
