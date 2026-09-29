import AppKit
import SwiftUI
import ApplicationServices

private final class CandidatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CandidateController: NSObject, NSWindowDelegate {
    let candidate = CandidateModel()
    private let model: AppModel
    private var panel: CandidatePanel!
    private var targetApp: NSRunningApplication?
    private var targetFocus: AXUIElement?
    private var clipboardVersion = 0
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var outsideMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var showing = false
    private var pending = false
    private var presentationToken = UUID()
    private var sessionID = UUID()
    var openLibrary: (() -> Void)?
    var openThemes: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        panel = CandidatePanel(contentRect: NSRect(origin: .zero, size: CandidateLayout.size(isImagePreviewExpanded: false)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.title = "剪贴历史"
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CandidateView(candidate: candidate, appModel: model))
        candidate.onCommit = { [weak self] in self?.commit($0) }
        candidate.onCancel = { [weak self] in self?.dismiss() }
        candidate.onPreviewChanged = { [weak self] in self?.resizeForPreview() }
        candidate.openLibrary = { [weak self] in self?.dismiss(); self?.openLibrary?() }
        candidate.openThemes = { [weak self] in self?.dismiss(); self?.openThemes?() }
    }

    var isVisible: Bool { panel.isVisible }
    var canReceiveShortcut: Bool {
        // Pausing capture must leave existing history available for pasting.
        !panel.isKeyWindow && model.isReady && AXIsProcessTrusted()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    /// The event tap must return immediately; clipboard decoding and AX queries run later.
    func requestFromShortcut(targetPID: pid_t, expectedClipboardVersion: Int) -> Bool {
        guard canReceiveShortcut, model.clipboard.changeCount == expectedClipboardVersion,
              let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier == targetPID,
              !target.isTerminated else { return false }
        guard !pending else { return true }
        pending = true
        let presentation = UUID()
        presentationToken = presentation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationToken == presentation else { return }
            self.pending = false
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  self.model.clipboard.changeCount == expectedClipboardVersion,
                  !self.model.clipboard.isCurrentPrivate else { return }
            self.show(target: target)
        }
        return true
    }

    func showManually() {
        if panel.isVisible { dismiss(); return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        show(target: target)
    }

    private func show(target: NSRunningApplication?) {
        dismiss()
        targetApp = target
        targetFocus = target.flatMap { Self.focusedElement(pid: $0.processIdentifier) }
        clipboardVersion = model.clipboard.changeCount
        let hasCurrent = model.clipboard.hasContent && !model.clipboard.isCurrentPrivate
        let current = hasCurrent ? model.clipboard.pickerSnapshot() : nil
        // A new copy arriving during lazy decoding must not be represented by an older preview.
        guard clipboardVersion == model.clipboard.changeCount else {
            return
        }
        candidate.prepare(history: model.records, current: current, hasCurrent: hasCurrent)
        if !AXIsProcessTrusted() && !model.isDemo { candidate.status = "未授权：选中后复制，再按 ⌘V" }
        if model.isDemo { candidate.status = "演示 · 独立剪贴板" }
        let anchor = Self.caretRect(focus: targetFocus) ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 18))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen { panel.setFrame(CandidatePlacement.frame(anchor: anchor, size: CandidateLayout.size(isImagePreviewExpanded: false), visibleFrame: screen.visibleFrame), display: false) }
        panel.appearance = model.appearance.nsAppearance
        // AX queries and decoding can outlive the original foreground application.
        guard model.clipboard.changeCount == clipboardVersion else { return }
        if let target {
            guard !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
        }
        sessionID = UUID()
        showing = true
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        // A nonactivating panel receives search input without activating this app.
        panel.contentView?.layoutSubtreeIfNeeded()
        if let field = Self.firstTextField(in: panel.contentView) { panel.makeFirstResponder(field) }
    }

    func dismiss() {
        cancelPendingPresentation()
        showing = false
        candidate.closeImagePreview()
        sessionID = UUID()
        panel?.orderOut(nil)
        for monitor in [keyMonitor, localMouseMonitor, outsideMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        localMouseMonitor = nil
        outsideMouseMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func cancelPendingPresentation() {
        pending = false
        presentationToken = UUID()
    }

    private func resizeForPreview() {
        guard showing, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = CandidatePlacement.resizedFrame(
            from: panel.frame,
            size: CandidateLayout.size(isImagePreviewExpanded: candidate.isImagePreviewExpanded),
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.showing, event.window === self.panel else { return event }
            // The input method owns navigation and Enter while composing Chinese, etc.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if event.keyCode == 49,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               self.candidate.handlePreviewSpace(isRepeat: event.isARepeat) { return nil }
            guard event.modifierFlags.intersection([.control, .option, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 125: self.candidate.moveSelection(1); return nil
            case 126: self.candidate.moveSelection(-1); return nil
            case 121: self.candidate.moveSelection(5); return nil
            case 116: self.candidate.moveSelection(-5); return nil
            case 36, 76: self.candidate.commit(); return nil
            case 53: self.candidate.cancel(); return nil
            default: return event
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.showing, event.window !== self.panel { self.dismiss() }
            return event
        }
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.showing, !self.model.isDemo,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.processIdentifier != self.targetApp?.processIdentifier { self.dismiss() }
            }
        }
    }

    private func commit(_ record: ClipRecord) {
        guard model.clipboard.changeCount == clipboardVersion else {
            candidate.status = "剪贴板已变化，请 Esc 后重新唤起"
            return
        }
        let isNative = record.id == candidate.nativeClipboardID
        if model.isDemo || !AXIsProcessTrusted() || targetApp == nil {
            do {
                if !isNative { try model.clipboard.restore(record); remember(record) }
                model.status = "内容已复制，请在目标应用按 ⌘V"
                dismiss()
            } catch { candidate.status = error.localizedDescription }
            return
        }
        guard let target = targetApp, !target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { dismiss(); return }
        if let expected = targetFocus {
            guard let actual = Self.focusedElement(pid: target.processIdentifier), CFEqual(expected, actual) else {
                candidate.status = "无法确认输入位置，请重新唤起"
                return
            }
        }
        let expectedFocus = targetFocus
        // Removing the key panel restores the target application's responder naturally.
        dismiss()
        let commitSession = sessionID
        let expectedClipboard = clipboardVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.sessionID == commitSession,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  self.model.clipboard.changeCount == expectedClipboard else { return }
            if let expectedFocus {
                guard let actual = Self.focusedElement(pid: target.processIdentifier), CFEqual(expectedFocus, actual) else { return }
            }
            do {
                if !isNative { try self.model.clipboard.restore(record) }
                guard PasteTrigger.postPaste(to: target.processIdentifier) else {
                    self.model.status = "内容已复制，未能直接粘贴，请按 ⌘V"
                    return
                }
                if !isNative { self.remember(record) }
                self.model.status = "已将所选内容粘贴到 \(target.localizedName ?? "原应用")"
            } catch { self.model.fail("粘贴失败", error.localizedDescription) }
        }
    }

    private func remember(_ record: ClipRecord) {
        var used = record
        used.lastUsedAt = Date()
        model.accept(used)
    }

    func windowDidResignKey(_ notification: Notification) {
        if showing { dismiss() }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let field = firstTextField(in: child) { return field } }
        return nil
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func caretRect(focus: AXUIElement?) -> NSRect? {
        guard let focus else { return nil }
        AXUIElementSetMessagingTimeout(focus, 0.08)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focus, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
              let selected else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focus, kAXBoundsForRangeParameterizedAttribute as CFString, selected, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        let value = bounds as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect),
              rect.minX.isFinite, rect.minY.isFinite, rect.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        return CandidatePlacement.appKitRect(fromAX: rect, primaryScreenTop: primary.frame.maxY)
    }
}
