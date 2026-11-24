import AppKit
import MyPasteCore

@MainActor
public final class CaptureController {
    private enum CaptureState {
        case idle
        case capturing
        /// 抓屏已完成、正在弹提示 / 建立覆盖窗：模态循环期间必须继续拒绝重入
        case presenting
    }

    public var pinBoard: PinBoard?

    private let environment: CaptureEnvironment
    private var session: CaptureSession?
    private var state: CaptureState = .idle
    private var captureTask: Task<Void, Never>?
    /// 超时 / 取消会递增代次并取消 Task；旧 Task 的 await 返回后必须先比对代次再执行任何副作用
    private var captureGeneration: UInt64 = 0

    public init(pinBoard: PinBoard? = nil, environment: CaptureEnvironment = CaptureEnvironment()) {
        self.pinBoard = pinBoard
        self.environment = environment
    }

    public var isSessionActive: Bool {
        session != nil
    }

    public func captureRegion() {
        beginCapture { [weak self] generation in
            guard let self else { return }
            let batch = try await self.environment.service.captureAllScreens()
            guard self.isCurrentCapture(generation) else { return }
            self.state = .presenting
            self.warnIncompleteScreens(batch.incompleteScreenCount)
            self.presentSession(screens: batch.screens, mode: .edit)
        }
    }

    public func openColorPicker() {
        beginCapture { [weak self] generation in
            guard let self else { return }
            let batch = try await self.environment.service.captureAllScreens()
            guard self.isCurrentCapture(generation) else { return }
            self.state = .presenting
            self.warnIncompleteScreens(batch.incompleteScreenCount)
            self.presentSession(screens: batch.screens, mode: .colorPicker)
        }
    }

    public func captureFullScreen(autoSave: Bool = true) {
        beginCapture { [weak self] generation in
            guard let self else { return }
            let captured = try await self.environment.service.captureScreen(under: NSEvent.mouseLocation)
            guard self.isCurrentCapture(generation) else { return }
            PasteboardWriter.writeImage(captured.image, to: self.environment.pasteboard)
            let result = CaptureResult(
                image: captured.image,
                screen: captured.screen,
                screenRect: captured.screen.frame,
                scale: captured.scale
            )
            self.archive(result, autoSave: autoSave)
            self.playSound()
            AppNotice.show(title: "已截取全屏并复制", duration: 1.8, dedupe: false)
        }
    }

    /// 所有截图入口共用：权限弹窗之前就进入 capturing，模态循环期间不会重入；
    /// defer 排在 presentSession / 弹窗之后，保证任何路径都复位状态。
    /// work 收到本次代次，必须在每个 await 返回后自行调用 isCurrentCapture 截断。
    private func beginCapture(_ work: @escaping @MainActor (UInt64) async throws -> Void) {
        guard session == nil, state == .idle else { return }
        state = .capturing
        guard ensurePermission() else {
            state = .idle
            return
        }
        captureGeneration &+= 1
        let generation = captureGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.captureGeneration == generation {
                    self.state = .idle
                    self.captureTask = nil
                }
            }
            do {
                try await work(generation)
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentCapture(generation) else { return }
                self.handleCaptureError(error)
            }
        }
        captureTask = task
        // SCScreenshotManager 不响应 Task 取消，卡住时靠状态复位让后续截图仍可用；
        // 旧 Task 若最终返回，由 isCurrentCapture 截断全部副作用，defer 也不会清掉新任务状态
        let timeout = environment.timeoutNanoseconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, self.state == .capturing, self.captureGeneration == generation else { return }
            task.cancel()
            self.captureGeneration &+= 1
            self.captureTask = nil
            self.state = .idle
            AppNotice.show(title: "截图超时", detail: "屏幕采集未响应，请重试。", duration: 3, dedupe: false)
        }
    }

    /// 超时守护 / cancelActiveSession 都会递增代次并取消 Task。
    /// 旧 Task 若不在 await 后截断，会写剪贴板、建会话，甚至把状态留在 .presenting，
    /// 而其 defer 因代次不匹配不复位，导致后续截图全部被拦截。
    private func isCurrentCapture(_ generation: UInt64) -> Bool {
        !Task.isCancelled && captureGeneration == generation
    }

    private func warnIncompleteScreens(_ count: Int) {
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "部分显示器未能冻结"
        alert.informativeText = "\(count) 块显示器无法冻结，本次截图只覆盖其余屏幕。"
        alert.addButton(withTitle: "继续")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate()
        alert.runModal()
    }

    public func cancelActiveSession() {
        captureTask?.cancel()
        captureTask = nil
        captureGeneration &+= 1
        state = .idle
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
                    PasteboardWriter.writeImage(result.image, to: self.environment.pasteboard)
                    self.archive(result, autoSave: true)
                    self.playSound()
                    AppNotice.show(title: "已复制到剪贴板", duration: 1.8, dedupe: false)
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
                    AppNotice.show(title: "已贴图", duration: 1.8, dedupe: false)
                },
                onSaved: { [weak self] result, url in
                    guard let self else { return }
                    self.archive(result, autoSave: false)
                    self.playSound()
                    AppNotice.show(
                        title: "已保存截图",
                        detail: url.lastPathComponent,
                        duration: 1.8,
                        dedupe: false
                    )
                },
                onSaveFailed: { [weak self] error in
                    guard let self else { return }
                    // 会话引用已在 onClosed 里释放；此处可能已有新会话，不能再清 session
                    self.presentSaveError(error)
                },
                onCancel: {},
                onColorPicked: { [weak self] _ in
                    self?.playSound()
                },
                onClosed: { [weak self] in
                    // 会话一结束就释放引用：写盘等异步收尾期间不能挡住新的截图
                    self?.session = nil
                }
            )
        )
        session = newSession
        newSession.start()
    }

    private func ensurePermission() -> Bool {
        if environment.service.hasPermission { return true }
        NSApp.activate()
        // CGRequestScreenCaptureAccess 只负责弹授权框，TCC 生效通常需要重启进程；
        // 同步返回值不能当成本次可抓屏的依据，否则随后 hasPermission 会再抛一次权限错误
        _ = environment.service.requestPermission()
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
        NSLog("MyPaste capture failed: %@", error.localizedDescription)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    private func archive(_ result: CaptureResult, autoSave: Bool) {
        // @MainActor 属性不能从后台队列读取，先取成局部引用再传入闭包
        let settings = environment.settings
        let historyStore = environment.historyStore
        let shouldAutoSave = autoSave && settings.autoSave
        let directory = settings.saveDirectory
        let format = settings.saveFormat
        let jpegQuality = settings.jpegQuality
        // 历史库始终存 PNG；自动保存按设置的格式另编码一次
        let url = directory.appendingPathComponent(
            ImageExporter.timestampedFileName(fileExtension: format.fileExtension)
        )
        let image = result.image
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // PNG 只编码一次，历史记录与自动保存复用同一份数据
            guard let png = ImageExporter.pngData(image) else {
                DispatchQueue.main.async {
                    self?.presentArchiveError(ImageExporter.ExportError.encodingFailed)
                }
                return
            }
            historyStore.record(image, pngData: png, onError: { error in
                DispatchQueue.main.async {
                    self?.presentArchiveError(error)
                }
            }, onPruneError: { error in
                DispatchQueue.main.async {
                    self?.presentHistoryPruneError(error)
                }
            })
            guard shouldAutoSave else { return }
            do {
                let data: Data
                if format == .png {
                    data = png
                } else {
                    guard let encoded = ImageExporter.data(
                        for: image,
                        fileExtension: format.fileExtension,
                        jpegQuality: jpegQuality
                    ) else {
                        throw ImageExporter.ExportError.encodingFailed
                    }
                    data = encoded
                }
                try SecureFileWriter.write(data, to: url)
            } catch {
                DispatchQueue.main.async {
                    self?.presentArchiveError(error)
                }
            }
        }
    }

    private func presentSaveError(_ error: Error) {
        presentErrorAlert(error, message: "保存截图失败", logPrefix: "MyPaste save failed")
    }

    private func presentArchiveError(_ error: Error) {
        presentErrorAlert(error, message: "保存截图失败", logPrefix: "MyPaste archive failed")
    }

    // 记录已写入，仅旧记录清理失败：文案不能报成"保存失败"，否则用户会误以为截图丢了。
    // 这类失败会持续复现（删不掉的文件一直留在盘上），用非模态提示条而不是 alert，
    // 否则之后每次截图都要手动关一次弹窗
    private func presentHistoryPruneError(_ error: Error) {
        NSLog("MyPaste history prune failed: %@", error.localizedDescription)
        AppNotice.show(
            title: "历史记录清理失败",
            detail: "截图已保存，但清理旧历史记录失败：\(error.localizedDescription)"
        )
    }

    /// 归档/保存类错误提示。截图覆盖窗为 .screenSaver 层级且不透明，
    /// 普通 level 的 alert 会被新会话覆盖窗挡住但模态循环仍在跑，表现为界面假死
    private func presentErrorAlert(_ error: Error, message: String, detail: String? = nil, logPrefix: String) {
        NSLog("%@: %@", logPrefix, error.localizedDescription)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate()
        alert.runModal()
    }

    private func playSound() {
        guard environment.settings.playSound else { return }
        NSSound(named: "Tink")?.play()
    }
}
