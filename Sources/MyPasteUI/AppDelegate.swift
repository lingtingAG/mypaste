import AppKit
import Carbon
import MyPasteCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let hotKeyCenter = HotKeyCenter()
    private let pinBoard = PinBoard()
    private lazy var captureController = CaptureController(pinBoard: pinBoard)
    private lazy var historyController = HistoryWindowController(pinBoard: pinBoard)
    private lazy var preferencesController: PreferencesWindowController = {
        PreferencesWindowController(settings: settings) { [weak self] in
            self?.reloadHotKeys() ?? []
        }
    }()

    private var statusItem: NSStatusItem?
    private var hotKeyFailures: [String] = []
    private var pendingURLs: [URL] = []
    private var hasFinishedLaunching = false

    public override init() {
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value) else { return }
        handleIncomingURL(url)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        // 录制快捷键期间暂停全局热键，结束后统一恢复（成功/取消都走 endRecording）
        ShortcutRecorderButton.onRecordingStateChange = { [weak self] isRecording in
            guard let self else { return }
            if isRecording {
                self.hotKeyCenter.unregisterAll()
            } else {
                self.hotKeyFailures = self.reloadHotKeys()
            }
        }
        hotKeyFailures = reloadHotKeys()
        _ = HistoryStore.shared
        if !settings.hasCompletedWelcome {
            settings.hasCompletedWelcome = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.presentFirstRunPrompt()
            }
        }
        hasFinishedLaunching = true
        let queued = pendingURLs
        pendingURLs.removeAll()
        queued.forEach(performIncomingURL)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        preferencesController.showWindow()
        return true
    }

    private func handleIncomingURL(_ url: URL) {
        guard hasFinishedLaunching else {
            pendingURLs.append(url)
            return
        }
        performIncomingURL(url)
    }

    private func performIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "mypaste" else { return }
        let action = ExternalURLAction(host: url.host)
        // 无可见界面的敏感动作不能被任意本地进程静默触发
        if action.requiresConfirmation, !confirmExternal(action) { return }
        switch action {
        case .capture: captureRegion()
        case .colorPicker: openColorPicker()
        case .history: showHistory()
        case .settings: showPreferences()
        case .pin: pinClipboard()
        case .fullScreen:
            statusItem?.menu?.cancelTracking()
            // 外部触发只写剪贴板与历史库，不自动保存到用户目录
            captureController.captureFullScreen(autoSave: false)
        case .quit: NSApp.terminate(nil)
        case .unknown: break
        }
    }

    private func confirmExternal(_ action: ExternalURLAction) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = action.confirmationTitle
        alert.informativeText = action.confirmationDetail
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "取消")
        // 层级高于截图覆盖窗，避免模态循环被挡住却仍在运行
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setupMainMenu() {
        NSApp.mainMenu = AppDelegate.makeMainMenu(target: self)
    }

    /// 主菜单构建。**internal** 便于回归测试枚举所有快捷键，
    /// 检查编辑器的组合键是否与主菜单撞车（菜单快捷键在事件进入第一响应者前就被消费）。
    /// `target` 传菜单项的响应者（AppDelegate 实例）；测试可传 nil。
    static func makeMainMenu(target: AnyObject?) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "关于 MyPaste", action: #selector(showAbout), keyEquivalent: "")
        about.target = target
        appMenu.addItem(about)
        let prefs = NSMenuItem(title: "设置…", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = target
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 MyPaste", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MyPaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        let undo = NSMenuItem(title: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        undo.target = nil
        editMenu.addItem(undo)
        let redo = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = nil
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        let cut = NSMenuItem(title: "剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        cut.target = nil
        editMenu.addItem(cut)
        let copy = NSMenuItem(title: "复制", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        copy.target = nil
        editMenu.addItem(copy)
        let paste = NSMenuItem(title: "粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        paste.target = nil
        editMenu.addItem(paste)
        editMenu.addItem(.separator())
        let selectAll = NSMenuItem(title: "全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        selectAll.target = nil
        editMenu.addItem(selectAll)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.image()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("MyPaste")
            button.toolTip = "MyPaste · \(settings.captureShortcut.displayString) 截图 · \(settings.pinShortcut.displayString) 贴图"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addMenuItem(
            to: menu,
            title: "截图",
            symbol: "viewfinder",
            action: #selector(captureRegion),
            shortcut: settings.captureShortcut.displayString
        )
        addMenuItem(
            to: menu,
            title: "贴图剪贴板",
            symbol: "pin",
            action: #selector(pinClipboard),
            shortcut: settings.pinShortcut.displayString
        )
        addMenuItem(
            to: menu,
            title: "全屏截图",
            symbol: "rectangle.dashed",
            action: #selector(captureFullScreen),
            shortcut: settings.fullScreenShortcut.displayString
        )
        addMenuItem(to: menu, title: "取色器", symbol: "eyedropper", action: #selector(openColorPicker))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: "历史记录…", symbol: "clock.arrow.circlepath", action: #selector(showHistory))
        addMenuItem(to: menu, title: "设置…", symbol: "gearshape", action: #selector(showPreferences))

        let pinItem = NSMenuItem(title: "贴图", action: nil, keyEquivalent: "")
        let pinMenu = NSMenu()
        pinMenu.addItem(menuItem(title: "显示全部贴图", symbol: "eye", action: #selector(showAllPins), enabled: pinBoard.count > 0))
        pinMenu.addItem(menuItem(title: "隐藏全部贴图", symbol: "eye.slash", action: #selector(hideAllPins), enabled: pinBoard.visibleCount > 0))
        pinMenu.addItem(menuItem(title: "关闭全部贴图", symbol: "xmark.circle", action: #selector(closeAllPins), enabled: pinBoard.count > 0))
        pinItem.submenu = pinMenu
        pinItem.image = symbolImage("pin")
        menu.addItem(pinItem)
        menu.addItem(.separator())

        let permissionTitle = ScreenPermission.isGranted ? "屏幕录制权限：已开启" : "屏幕录制权限：未开启"
        let permissionItem = addMenuItem(
            to: menu,
            title: permissionTitle,
            symbol: ScreenPermission.isGranted ? "checkmark.shield" : "exclamationmark.shield",
            action: #selector(openPermissionSettings)
        )
        if !ScreenPermission.isGranted {
            permissionItem.attributedTitle = coloredTitle(permissionTitle, color: .systemOrange)
        }

        if !hotKeyFailures.isEmpty {
            let failures = NSMenuItem(
                title: "快捷键不可用：\(hotKeyFailures.joined(separator: "、"))",
                action: #selector(showPreferences),
                keyEquivalent: ""
            )
            failures.target = self
            failures.image = symbolImage("exclamationmark.triangle")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.systemOrange,
            ]
            failures.attributedTitle = NSAttributedString(string: failures.title, attributes: attributes)
            menu.addItem(failures)
        }

        menu.addItem(.separator())
        addMenuItem(to: menu, title: "关于 MyPaste", symbol: "info.circle", action: #selector(showAbout))
        let quit = NSMenuItem(title: "退出 MyPaste", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = symbolImage("power")
        menu.addItem(quit)
    }

    @discardableResult
    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        symbol: String,
        action: Selector,
        shortcut: String? = nil
    ) -> NSMenuItem {
        let item = menuItem(title: title, symbol: symbol, action: action)
        if let shortcut {
            let attributed = NSMutableAttributedString(attributedString: item.attributedTitle ?? coloredTitle(title, color: .labelColor))
            attributed.append(NSAttributedString(
                string: "    \(shortcut)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            item.attributedTitle = attributed
        }
        menu.addItem(item)
        return item
    }

    private func menuItem(title: String, symbol: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.image = symbolImage(symbol)
        return item
    }

    private func coloredTitle(_ title: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: color,
        ])
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    @discardableResult
    private func reloadHotKeys() -> [String] {
        hotKeyCenter.unregisterAll()
        var failures: [String] = []
        if hotKeyCenter.register(settings.captureShortcut, handler: { [weak self] in
            Task { @MainActor in self?.captureRegion() }
        }) == nil {
            failures.append("截图 \(settings.captureShortcut.displayString)")
        }
        if hotKeyCenter.register(settings.pinShortcut, handler: { [weak self] in
            Task { @MainActor in self?.pinClipboard() }
        }) == nil {
            failures.append("贴图 \(settings.pinShortcut.displayString)")
        }
        if hotKeyCenter.register(settings.fullScreenShortcut, handler: { [weak self] in
            Task { @MainActor in self?.captureFullScreen() }
        }) == nil {
            failures.append("全屏截图 \(settings.fullScreenShortcut.displayString)")
        }
        hotKeyFailures = failures
        if !failures.isEmpty {
            NSLog("MyPaste hotkey registration failed: %@", failures.joined(separator: ", "))
        }
        return failures
    }

    private func presentFirstRunPrompt() {
        let granted = ScreenPermission.isGranted
        let alert = NSAlert()
        alert.messageText = "MyPaste 已就绪"
        alert.informativeText = "按 \(settings.captureShortcut.displayString) 截图，按 \(settings.pinShortcut.displayString) 贴图。\n\n截图使用 macOS 原生 ScreenCaptureKit，需要“屏幕录制”权限。所有图片只保存在本机。"
        alert.addButton(withTitle: granted ? "开始使用" : "授予屏幕录制权限")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, !granted {
            _ = ScreenPermission.request()
            if !ScreenPermission.isGranted {
                let followUp = NSAlert()
                followUp.messageText = "请在系统设置中授权"
                followUp.informativeText = "打开“系统设置 › 隐私与安全性 › 屏幕录制”，勾选 MyPaste 后重新启动应用。"
                followUp.addButton(withTitle: "打开系统设置")
                followUp.addButton(withTitle: "稍后")
                if followUp.runModal() == .alertFirstButtonReturn {
                    ScreenPermission.openSystemSettings()
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func captureRegion() {
        statusItem?.menu?.cancelTracking()
        captureController.captureRegion()
    }

    @objc private func captureFullScreen() {
        statusItem?.menu?.cancelTracking()
        captureController.captureFullScreen()
    }

    @objc private func openColorPicker() {
        statusItem?.menu?.cancelTracking()
        captureController.openColorPicker()
    }

    @objc private func pinClipboard() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return }
        guard let content = PasteboardReader.read() else {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "剪贴板里没有图片或文字"
            alert.informativeText = "复制一张图片、一段文字或一个颜色值，再按 \(settings.pinShortcut.displayString)。"
            NSApp.activate()
            alert.runModal()
            return
        }
        switch content {
        case let .image(image, logicalSize):
            let natural = logicalSize ?? CGSize(width: image.width, height: image.height)
            pinBoard.present(
                image: image,
                at: nil,
                screen: screen,
                scale: max(1, screen.backingScaleFactor),
                originalText: nil,
                preferredSize: natural
            )
        case let .text(text):
            guard let card = ClipboardCard.make(from: text) else {
                NSSound.beep()
                return
            }
            pinBoard.present(
                image: card.image,
                at: nil,
                screen: screen,
                scale: 2,
                originalText: text,
                preferredSize: card.displaySize
            )
        }
        if settings.playSound {
            NSSound(named: "Tink")?.play()
        }
    }

    @objc private func showHistory() {
        historyController.showWindow()
    }

    @objc private func showPreferences() {
        preferencesController.showWindow()
    }

    @objc private func showAllPins() {
        pinBoard.showAll()
    }

    @objc private func hideAllPins() {
        pinBoard.hideAll()
    }

    @objc private func closeAllPins() {
        pinBoard.closeAll()
    }

    @objc private func openPermissionSettings() {
        ScreenPermission.openSystemSettings()
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "原生 macOS 截图与贴图工具\n按 \(settings.captureShortcut.displayString) 截图 · 按 \(settings.pinShortcut.displayString) 贴图\n\nScreenCaptureKit · AppKit · 本地处理",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MyPaste",
            .applicationVersion: "1.0.0",
            .version: "1.0.0",
            .credits: credits,
        ])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
