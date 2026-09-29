import AppKit
import SwiftUI
import ApplicationServices
import Carbon

@main
enum ClipboardShelfLauncher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ShelfAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ShelfAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private var previousApp: NSRunningApplication?
    private var picker: CandidateController!
    private var pasteTrigger: PasteTrigger!
    private var permissionTimer: Timer?
    private var buildVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development" }
    private var displayVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
    private var commandVEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "commandVEnabled") == nil || UserDefaults.standard.bool(forKey: "commandVEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "commandVEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "ClipboardShelfDemoMode") as? Bool == true
        model = AppModel(isDemo: demo)
        model.returnToPreviousApp = { [weak self] paste in self?.returnToApp(paste: paste) }
        picker = CandidateController(model: model)
        picker.openLibrary = { [weak self] in self?.showWindow() }
        picker.openThemes = { [weak self] in self?.showWindow(); self?.model.showingThemes = true }
        pasteTrigger = PasteTrigger()
        pasteTrigger.canBeginHold = { [weak self] in self?.picker.canReceiveShortcut ?? false }
        pasteTrigger.onTrigger = { [weak self] pid, version in
            self?.picker.requestFromShortcut(targetPID: pid, expectedClipboardVersion: version) ?? false
        }
        pasteTrigger.onGestureCancelled = { [weak self] in self?.picker.cancelPendingPresentation() }
        pasteTrigger.onUnavailable = { [weak self] in self?.model.status = $0 }
        setupMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "拾光剪贴板")
            button.toolTip = "拾光 · 短按 ⌘V 粘贴 · 长按 ⌘V 选择历史"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if !demo {
            shortcut = GlobalShortcut { [weak self] in self?.showCandidates() }
            model.shortcutAvailable = shortcut?.register() ?? false
        }
        model.onReady = { [weak self] in
            guard let self else { return }
            if demo { self.picker.showManually(); return }
            self.refreshPasteTrigger()
            let firstLaunch = !UserDefaults.standard.bool(forKey: "candidateOnboardingShown")
            let needsUpgradeNotice = self.commandVEnabled && UserDefaults.standard.string(forKey: "candidatePermissionNoticeBuild") != self.buildVersion
            if !AXIsProcessTrusted() && (firstLaunch || needsUpgradeNotice) {
                self.showOnboarding()
            }
        }
        model.start()
        if !demo {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPasteTrigger() }
            }
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于拾光剪贴板", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏拾光", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出拾光", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let open = windowMenu.addItem(withTitle: "管理历史记录", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let state = menu.addItem(withTitle: longPressStatus, action: nil, keyEquivalent: "")
            state.isEnabled = false
            menu.addItem(.separator())
            for (title, selector) in [("选择剪贴历史   ⌘⇧V", #selector(showCandidates)), ("管理历史记录…", #selector(showWindow)), ("皮肤与背景图片…", #selector(showThemes)), (model.isPaused ? "继续记录" : "暂停记录", #selector(togglePause))] {
                let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
                item.target = self
            }
            menu.addItem(.separator())
            let enabled = pasteTrigger.isRunning
            let intercept = menu.addItem(withTitle: enabled ? "关闭长按 ⌘V 候选栏" : "开启长按 ⌘V 候选栏…", action: #selector(toggleCommandV), keyEquivalent: "")
            intercept.target = self
            let permission = menu.addItem(withTitle: "辅助功能权限…", action: #selector(requestPermission), keyEquivalent: "")
            permission.target = self
            let diagnostics = menu.addItem(withTitle: "检查长按状态…", action: #selector(showShortcutStatus), keyEquivalent: "")
            diagnostics.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出拾光", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { showCandidates() }
    }

    @objc private func showCandidates() { picker.showManually() }
    @objc private func showThemes() { showWindow(); model.showingThemes = true }

    @objc func showWindow() {
        picker.dismiss()
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "拾光 · 管理历史记录"
            window.minSize = NSSize(width: 950, height: 620)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: ShelfView(model: model))
            window.center()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.searchFocusRequest = UUID()
    }

    private func returnToApp(paste: Bool) {
        guard let target = previousApp, !target.isTerminated else {
            model.status = "内容已复制，请切换到目标应用后按 ⌘V"
            return
        }
        if paste && !model.isDemo {
            let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            guard trusted else {
                model.fail("内容已复制", "直接粘贴需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许拾光剪贴板。你也可以切换回原应用，直接按 ⌘V。")
                return
            }
        }
        window.orderOut(nil)
        let clipboardVersion = paste ? NSPasteboard.general.changeCount : 0
        target.activate(options: [])
        guard paste, !model.isDemo else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  NSPasteboard.general.changeCount == clipboardVersion else {
                self?.model.status = "内容已复制，目标应用尚未激活，请按 ⌘V 粘贴"
                return
            }
            _ = PasteTrigger.postPaste(to: target.processIdentifier)
        }
    }

    @objc private func togglePause() { model.isPaused.toggle() }
    @objc private func captureCurrent() { model.clipboard.captureNow() }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "拾光剪贴板"
        alert.informativeText = "版本 \(displayVersion)\n\n短按 ⌘V 直接粘贴，长按约 0.4 秒打开历史。\n↑↓ 选择 · 回车粘贴 · Esc 取消\n滚轮浏览全部历史，直接输入关键词搜索。\n\n\(longPressStatus)\n辅助入口：⌘⇧V 或菜单栏图标\n所有记录保存在此 Mac。"
        alert.runModal()
    }

    private func refreshPasteTrigger() {
        defer { statusItem?.button?.toolTip = "拾光 · \(longPressStatus)" }
        guard model.isReady, !model.isDemo else { return }
        if !commandVEnabled || !AXIsProcessTrusted() {
            if pasteTrigger.isRunning { pasteTrigger.stop(); picker.dismiss() }
        } else if !pasteTrigger.isRunning {
            _ = pasteTrigger.start()
        }
    }

    private var longPressStatus: String {
        if model.isDemo { return "演示模式：未启用全局快捷键" }
        if !commandVEnabled { return "长按 ⌘V：已关闭" }
        if !AXIsProcessTrusted() { return "长按 ⌘V：辅助功能授权未生效" }
        if !model.isReady { return "长按 ⌘V：历史尚未就绪" }
        if IsSecureEventInputEnabled() { return "长按 ⌘V：系统安全输入暂时阻止拦截" }
        if !pasteTrigger.isRunning { return "长按 ⌘V：键盘监听未启动" }
        return "长按 ⌘V：已就绪（按住两个键 0.4 秒）"
    }

    @objc private func showShortcutStatus() {
        refreshPasteTrigger()
        let trusted = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.messageText = longPressStatus
        let details = "版本 \(displayVersion)\n辅助功能：\(trusted ? "已授权" : "未授权或旧授权已失效")\n键盘监听：\(pasteTrigger.isRunning ? "运行中" : "未运行")\n\n当前应用：\n\(Bundle.main.bundlePath)"
        alert.informativeText = details + (trusted ? "\n\n先按住 ⌘，再按住 V，两个键保持约 0.4 秒。" : "\n\n更新后系统可能仍保留旧版本的授权。请在辅助功能列表移除旧的拾光剪贴板，再用「+」添加上面的当前应用并开启。")
        alert.addButton(withTitle: trusted ? "关闭" : "打开辅助功能设置")
        if !trusted { alert.addButton(withTitle: "稍后") }
        if alert.runModal() == .alertFirstButtonReturn && !trusted { requestPermission() }
    }

    @objc private func toggleCommandV() {
        if pasteTrigger.isRunning {
            commandVEnabled = false
            pasteTrigger.stop()
            picker.dismiss()
            model.status = "已恢复系统默认 ⌘V"
        } else {
            commandVEnabled = true
            requestPermission()
        }
    }

    @objc private func requestPermission() {
        commandVEnabled = true
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        refreshPasteTrigger()
    }

    private func showOnboarding() {
        UserDefaults.standard.set(true, forKey: "candidateOnboardingShown")
        UserDefaults.standard.set(buildVersion, forKey: "candidatePermissionNoticeBuild")
        let alert = NSAlert()
        alert.messageText = "长按候选栏尚未启用"
        alert.informativeText = "当前版本的辅助功能授权未生效，⌘V 仍由系统直接粘贴。\n\n请在「系统设置 → 隐私与安全性 → 辅助功能」允许拾光剪贴板。若更新前已经授权，请移除旧条目，再用「+」添加当前版本并开启：\n\(Bundle.main.bundlePath)\n\n授权生效后，同时按住 ⌘ 和 V 约 0.4 秒可打开历史。菜单栏右键可随时检查长按状态。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { requestPermission() }
        // Deferring the permission prompt must not silently disable the preference.
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showCandidates(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try model?.flush(); return .terminateNow }
        catch {
            showWindow()
            let alert = NSAlert()
            alert.messageText = "暂时无法退出：历史尚未保存"
            alert.informativeText = "\(error.localizedDescription)\n\n请通过「管理与备份」导出记录，或修复数据目录的写入权限后重试。"
            alert.addButton(withTitle: "继续使用")
            alert.runModal()
            return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.clipboard.stop()
        shortcut?.unregister()
        pasteTrigger?.stop()
        picker?.dismiss()
        permissionTimer?.invalidate()
    }
}
