import AppKit
import MyPasteCore
import ServiceManagement

private final class PreferencesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

private final class PreferencesRootView: NSView {
    override var isFlipped: Bool { true }
}

private enum HotkeyKind {
    case capture
    case pin
    case fullScreen
}

@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let onHotkeysChanged: () -> [String]

    private var window: PreferencesWindow?
    private var captureRecorder: ShortcutRecorderButton?
    private var pinRecorder: ShortcutRecorderButton?
    private var fullScreenRecorder: ShortcutRecorderButton?
    private var hotkeyWarningLabel: NSTextField?
    private var soundSwitch: NSSwitch?
    private var magnifierSwitch: NSSwitch?
    private var autoSaveSwitch: NSSwitch?
    private var launchSwitch: NSSwitch?
    private var folderLabel: NSTextField?
    private var historyPopup: NSPopUpButton?
    private var historyDiskPopup: NSPopUpButton?
    private var permissionLabel: NSTextField?
    private var permissionButton: NSButton?
    private var appActiveObserver: NSObjectProtocol?

    public init(settings: AppSettings = .shared, onHotkeysChanged: @escaping () -> [String]) {
        self.settings = settings
        self.onHotkeysChanged = onHotkeysChanged
        super.init()
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionState() }
        }
    }

    deinit {
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
        }
    }

    public func showWindow() {
        ensureWindow()
        syncState()
        NSApp.activate()
        if window?.isVisible != true {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func makeSnapshotContentView() -> NSView? {
        ensureWindow()
        syncState()
        guard let window, let root = window.contentView else { return nil }
        let dark = NSAppearance(named: .darkAqua)
        window.appearance = dark
        root.appearance = dark
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        root.layoutSubtreeIfNeeded()
        return root
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyPaste 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let root = PreferencesRootView()
        window.contentView = root

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        // Hotkeys
        let capture = ShortcutRecorderButton(shortcut: settings.captureShortcut)
        let pin = ShortcutRecorderButton(shortcut: settings.pinShortcut)
        let fullScreen = ShortcutRecorderButton(shortcut: settings.fullScreenShortcut)
        captureRecorder = capture
        pinRecorder = pin
        fullScreenRecorder = fullScreen
        capture.onRecord = { [weak self] shortcut in self?.setShortcut(shortcut, kind: .capture) }
        pin.onRecord = { [weak self] shortcut in self?.setShortcut(shortcut, kind: .pin) }
        fullScreen.onRecord = { [weak self] shortcut in self?.setShortcut(shortcut, kind: .fullScreen) }

        let warning = NSTextField(labelWithString: "")
        warning.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        warning.textColor = .systemOrange
        warning.lineBreakMode = .byWordWrapping
        warning.maximumNumberOfLines = 2
        warning.preferredMaxLayoutWidth = 500
        warning.translatesAutoresizingMaskIntoConstraints = false
        hotkeyWarningLabel = warning

        let resetHotkeys = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetHotkeys))
        resetHotkeys.bezelStyle = .rounded
        resetHotkeys.controlSize = .small

        let hotkeySection = makeSection(
            title: "快捷键",
            rows: [
                makeRow(title: "截图", control: capture),
                makeRow(title: "贴图剪贴板", control: pin),
                makeRow(title: "全屏截图到剪贴板", control: fullScreen),
                warning,
                resetHotkeys,
            ]
        )

        // Screenshot settings
        let sound = makeSwitch(action: #selector(soundToggled(_:)), state: settings.playSound)
        let magnifier = makeSwitch(action: #selector(magnifierToggled(_:)), state: settings.showMagnifier)
        let autoSave = makeSwitch(action: #selector(autoSaveToggled(_:)), state: settings.autoSave)
        soundSwitch = sound
        magnifierSwitch = magnifier
        autoSaveSwitch = autoSave

        let folder = NSTextField(labelWithString: displayPath(settings.saveDirectory))
        folder.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        folder.maximumNumberOfLines = 1
        folder.translatesAutoresizingMaskIntoConstraints = false
        folder.widthAnchor.constraint(equalToConstant: 250).isActive = true
        folderLabel = folder
        let chooseFolder = NSButton(title: "选择…", target: self, action: #selector(chooseFolder))
        chooseFolder.bezelStyle = .rounded
        chooseFolder.controlSize = .small
        let folderStack = NSStackView(views: [folder, chooseFolder])
        folderStack.orientation = .horizontal
        folderStack.alignment = .centerY
        folderStack.spacing = 8

        let historyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for limit in [20, 50, 100, 200] {
            historyPopup.addItem(withTitle: "\(limit) 张")
            historyPopup.lastItem?.tag = limit
        }
        historyPopup.target = self
        historyPopup.action = #selector(historyLimitChanged(_:))
        historyPopup.controlSize = .regular
        self.historyPopup = historyPopup

        let historyDiskPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for limit in [200, 500, 1024, 2048] {
            historyDiskPopup.addItem(withTitle: "\(limit) MB")
            historyDiskPopup.lastItem?.tag = limit
        }
        historyDiskPopup.target = self
        historyDiskPopup.action = #selector(historyDiskLimitChanged(_:))
        historyDiskPopup.controlSize = .regular
        self.historyDiskPopup = historyDiskPopup

        let screenshotSection = makeSection(
            title: "截图与保存",
            rows: [
                makeRow(title: "复制后播放声音", control: sound),
                makeRow(title: "显示放大镜与像素取色", control: magnifier),
                makeRow(title: "复制后自动保存到文件夹", control: autoSave),
                makeRow(title: "保存位置", control: folderStack),
                makeRow(title: "保留历史记录", control: historyPopup),
                makeRow(title: "历史磁盘上限", control: historyDiskPopup),
            ]
        )

        // System settings
        let launch = makeSwitch(action: #selector(launchAtLoginToggled(_:)), state: false)
        launchSwitch = launch
        let permissionLabel = NSTextField(labelWithString: "")
        permissionLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false
        self.permissionLabel = permissionLabel
        let openPermission = NSButton(title: "打开系统设置", target: self, action: #selector(openPermissionSettings))
        openPermission.bezelStyle = .rounded
        openPermission.controlSize = .small
        permissionButton = openPermission
        let permissionStack = NSStackView(views: [permissionLabel, openPermission])
        permissionStack.orientation = .horizontal
        permissionStack.alignment = .centerY
        permissionStack.spacing = 10

        let systemSection = makeSection(
            title: "系统",
            rows: [
                makeRow(title: "开机自动启动", control: launch),
                makeRow(title: "屏幕录制权限", control: permissionStack),
            ]
        )

        content.addArrangedSubview(hotkeySection)
        content.addArrangedSubview(screenshotSection)
        content.addArrangedSubview(systemSection)

        let footer = NSTextField(labelWithString: "MyPaste 常驻菜单栏；屏幕录制权限变更后需要重新启动应用。")
        footer.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        let done = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(done)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -26),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            done.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            done.widthAnchor.constraint(equalToConstant: 90),
        ])

        self.window = window
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func makeSection(title: String, rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.widthAnchor.constraint(equalToConstant: 500).isActive = true
        stack.addArrangedSubview(rule)
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(8, after: rule)
        for row in rows {
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func makeRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeSwitch(action: Selector, state: Bool) -> NSSwitch {
        let control = NSSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        control.state = state ? .on : .off
        control.target = self
        control.action = action
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }

    private func syncState() {
        captureRecorder?.shortcut = settings.captureShortcut
        pinRecorder?.shortcut = settings.pinShortcut
        fullScreenRecorder?.shortcut = settings.fullScreenShortcut
        soundSwitch?.state = settings.playSound ? .on : .off
        magnifierSwitch?.state = settings.showMagnifier ? .on : .off
        autoSaveSwitch?.state = settings.autoSave ? .on : .off
        folderLabel?.stringValue = displayPath(settings.saveDirectory)
        if let popup = historyPopup {
            if let index = popup.itemArray.firstIndex(where: { $0.tag == settings.historyLimit }) {
                popup.selectItem(at: index)
            } else {
                popup.selectItem(at: 1)
            }
        }
        if let popup = historyDiskPopup {
            if let index = popup.itemArray.firstIndex(where: { $0.tag == settings.historyDiskLimitMB }) {
                popup.selectItem(at: index)
            } else {
                popup.selectItem(at: 1)
            }
        }
        refreshPermissionState()
        refreshLaunchAtLoginState()
    }

    private func refreshPermissionState() {
        let granted = ScreenPermission.isGranted
        permissionLabel?.stringValue = granted ? "已开启" : "未开启"
        permissionLabel?.textColor = granted ? .systemGreen : .systemOrange
        permissionButton?.title = granted ? "系统设置" : "去开启"
    }

    private func refreshLaunchAtLoginState() {
        let status = SMAppService.mainApp.status
        launchSwitch?.state = status == .enabled ? .on : .off
    }

    private func setShortcut(_ shortcut: Shortcut, kind: HotkeyKind) {
        let conflict: Bool
        switch kind {
        case .capture:
            conflict = shortcut == settings.pinShortcut || shortcut == settings.fullScreenShortcut
        case .pin:
            conflict = shortcut == settings.captureShortcut || shortcut == settings.fullScreenShortcut
        case .fullScreen:
            conflict = shortcut == settings.captureShortcut || shortcut == settings.pinShortcut
        }
        guard !conflict else {
            NSSound.beep()
            hotkeyWarningLabel?.stringValue = "该快捷键已经被 MyPaste 的其他功能占用，请换一个。"
            syncState()
            return
        }

        switch kind {
        case .capture: settings.captureShortcut = shortcut
        case .pin: settings.pinShortcut = shortcut
        case .fullScreen: settings.fullScreenShortcut = shortcut
        }
        applyHotkeys()
    }

    private func applyHotkeys() {
        let failures = onHotkeysChanged()
        if failures.isEmpty {
            hotkeyWarningLabel?.stringValue = ""
        } else {
            hotkeyWarningLabel?.stringValue = "快捷键注册失败：\(failures.joined(separator: "、"))。可能被其他应用占用。"
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作失败"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @objc private func soundToggled(_ sender: NSSwitch) {
        settings.playSound = sender.state == .on
    }

    @objc private func magnifierToggled(_ sender: NSSwitch) {
        settings.showMagnifier = sender.state == .on
    }

    @objc private func autoSaveToggled(_ sender: NSSwitch) {
        settings.autoSave = sender.state == .on
    }

    @objc private func launchAtLoginToggled(_ sender: NSSwitch) {
        let enable = sender.state == .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = enable ? .off : .on
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法更改开机启动"
            alert.informativeText = "\(error.localizedDescription)\n\n请先将 MyPaste 移动到“应用程序”文件夹后再试。"
            if let window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func historyLimitChanged(_ sender: NSPopUpButton) {
        let limit = sender.selectedTag()
        guard limit > 0 else { return }
        settings.historyLimit = limit
        HistoryStore.shared.pruneAsync(limit: limit)
    }

    @objc private func historyDiskLimitChanged(_ sender: NSPopUpButton) {
        let limit = sender.selectedTag()
        guard limit > 0 else { return }
        settings.historyDiskLimitMB = limit
        HistoryStore.shared.pruneAsync(limit: settings.historyLimit, diskLimitMB: limit)
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.saveDirectory = url
            self?.folderLabel?.stringValue = self?.displayPath(url) ?? url.path
        }
    }

    @objc private func openPermissionSettings() {
        ScreenPermission.openSystemSettings()
    }

    @objc private func resetHotkeys() {
        settings.captureShortcut = .capture
        settings.pinShortcut = .pin
        settings.fullScreenShortcut = .fullScreen
        syncState()
        applyHotkeys()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Recording monitors are cleaned up by the recorder's own observers.
    }
}
