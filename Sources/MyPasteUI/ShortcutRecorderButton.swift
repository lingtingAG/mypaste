import AppKit
import Carbon.HIToolbox
import MyPasteCore

public final class ShortcutRecorderButton: NSButton {
    public var shortcut: Shortcut {
        didSet { updateTitle() }
    }
    public var onRecord: ((Shortcut) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private static weak var activeRecorder: ShortcutRecorderButton?
    /// 录制开始/结束时通知（true=开始）。宿主应暂停/恢复全局热键，
    /// 否则已注册组合会在 Carbon 层被吞掉并直接触发截图，录制不到也来不及取消。
    public static var onRecordingStateChange: ((Bool) -> Void)?

    public init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 176, height: 26))
        bezelStyle = .rounded
        controlSize = .regular
        focusRingType = .none
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        alignment = .center
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 176).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setAccessibilityLabel("录制快捷键")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        cleanupMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        guard let window else {
            endRecording()
            return
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.endRecording()
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            endRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        Self.activeRecorder?.endRecording()
        Self.activeRecorder = self
        isRecording = true
        Self.onRecordingStateChange?(true)
        title = "请按下快捷键…"
        bezelColor = .controlAccentColor
        contentTintColor = .white
        window?.makeKey()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            return nil
        }
        guard let shortcut = Shortcut.from(event: event) else {
            NSSound.beep()
            return nil
        }
        guard Self.isAllowedGlobally(shortcut) else {
            NSSound.beep()
            return nil
        }
        endRecording()
        self.shortcut = shortcut
        onRecord?(shortcut)
        return nil
    }

    private func endRecording() {
        guard isRecording || eventMonitor != nil else {
            return
        }
        isRecording = false
        cleanupMonitor()
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
        }
        Self.onRecordingStateChange?(false)
        bezelColor = nil
        contentTintColor = nil
        updateTitle()
    }

    private func cleanupMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func updateTitle() {
        guard !isRecording else { return }
        title = shortcut.displayString
    }

    private static func isAllowedGlobally(_ shortcut: Shortcut) -> Bool {
        if shortcut.hasCommand || shortcut.hasOption || shortcut.hasControl {
            return true
        }
        let functionKeyCodes: Set<UInt32> = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5),
            UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10),
            UInt32(kVK_F11), UInt32(kVK_F12), UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15),
            UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
        ]
        return functionKeyCodes.contains(shortcut.keyCode)
    }
}
