import AppKit
import MyPasteCore

@MainActor
public final class CaptureController {
    public var pinBoard: PinBoard?

    private let service = ScreenCaptureService()
    private var session: CaptureSession?
    private var isCapturing = false

    public init(pinBoard: PinBoard? = nil) {
        self.pinBoard = pinBoard
    }

    public var isSessionActive: Bool {
        session != nil
    }

    public func captureRegion() {
        guard session == nil, !isCapturing else { return }
        guard ensurePermission() else { return }
        isCapturing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let screens = try await self.service.captureAllScreens()
                self.isCapturing = false
                self.presentSession(screens: screens, mode: .edit)
            } catch {
                self.isCapturing = false
                self.handleCaptureError(error)
            }
        }
    }

    public func openColorPicker() {
        guard session == nil, !isCapturing else { return }
        guard ensurePermission() else { return }
        isCapturing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let screens = try await self.service.captureAllScreens()
                self.isCapturing = false
                self.presentSession(screens: screens, mode: .colorPicker)
            } catch {
                self.isCapturing = false
                self.handleCaptureError(error)
            }
        }
    }

    public func captureFullScreen() {
        guard session == nil, !isCapturing else { return }
        guard ensurePermission() else { return }
        isCapturing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let screens = try await self.service.captureAllScreens()
                self.isCapturing = false
                let mousePoint = NSEvent.mouseLocation
                guard let captured = screens.first(where: { $0.frame.contains(mousePoint) }) ?? screens.first else {
                    self.handleCaptureError(ScreenCaptureError.noDisplays)
                    return
                }
                PasteboardWriter.writeImage(captured.image)
                let result = CaptureResult(
                    image: captured.image,
                    screen: captured.screen,
                    screenRect: captured.screen.frame,
                    scale: captured.scale
                )
                self.archive(result, autoSave: true)
                self.playSound()
            } catch {
                self.isCapturing = false
                self.handleCaptureError(error)
            }
        }
    }

    public func cancelActiveSession() {
        session?.cancel()
    }

    private func presentSession(screens: [CapturedScreen], mode: CaptureInteractionMode) {
        guard session == nil else { return }
        let newSession = CaptureSession(
            capturedScreens: screens,
            mode: mode,
            callbacks: CaptureSession.Callbacks(
                onCopy: { [weak self] result in
                    guard let self else { return }
                    PasteboardWriter.writeImage(result.image)
                    self.archive(result, autoSave: true)
                    self.playSound()
                    self.session = nil
                },
                onPin: { [weak self] result in
                    guard let self else { return }
                    self.pinBoard?.present(
                        image: result.image,
                        at: result.screenRect,
                        screen: result.screen,
                        scale: result.scale
                    )
                    self.archive(result, autoSave: true)
                    self.playSound()
                    self.session = nil
                },
                onSaved: { [weak self] result, _ in
                    guard let self else { return }
                    self.archive(result, autoSave: false)
                    self.playSound()
                    self.session = nil
                },
                onCancel: { [weak self] in
                    self?.session = nil
                },
                onColorPicked: { [weak self] _ in
                    self?.playSound()
                    self?.session = nil
                }
            )
        )
        session = newSession
        newSession.start()
    }

    private func ensurePermission() -> Bool {
        if service.hasPermission { return true }
        NSApp.activate()
        if service.requestPermission() { return true }
        presentPermissionAlert()
        return false
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要“屏幕录制”权限"
        alert.informativeText = """
        MyPaste 使用 macOS 原生 ScreenCaptureKit 截取屏幕，整个过程在本机完成。

        请在“系统设置 › 隐私与安全性 › 屏幕录制”中勾选 MyPaste，然后重新启动应用。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenPermission.openSystemSettings()
        }
    }

    private func handleCaptureError(_ error: Error) {
        if case ScreenCaptureError.permissionDenied = error {
            presentPermissionAlert()
            return
        }
        NSLog("MyPaste capture failed: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    private func archive(_ result: CaptureResult, autoSave: Bool) {
        HistoryStore.shared.record(result.image)
        guard autoSave, AppSettings.shared.autoSave else { return }
        let directory = AppSettings.shared.saveDirectory
        let url = directory.appendingPathComponent(ImageExporter.timestampedFileName())
        let image = result.image
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try ImageExporter.write(image, to: url)
            } catch {
                NSLog("MyPaste auto-save failed: \(error.localizedDescription)")
            }
        }
    }

    private func playSound() {
        guard AppSettings.shared.playSound else { return }
        NSSound(named: "Tink")?.play()
    }
}
