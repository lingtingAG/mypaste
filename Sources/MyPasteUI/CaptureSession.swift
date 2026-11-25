import AppKit
import MyPasteCore
import UniformTypeIdentifiers

/// 保存路径已编码的落盘数据：历史库可直接复用同一份 PNG，避免整图二次编码
public struct EncodedCapture: Sendable {
    public let data: Data
    public let fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

public struct CaptureResult {
    public let image: CGImage
    public let screen: NSScreen
    public let screenRect: CGRect
    public let scale: CGFloat
    public let createdAt: Date
    /// 已编码的落盘数据（保存路径填充）：与 image 同源，供历史库复用
    public var encoded: EncodedCapture?

    public init(
        image: CGImage,
        screen: NSScreen,
        screenRect: CGRect,
        scale: CGFloat,
        createdAt: Date = Date(),
        encoded: EncodedCapture? = nil
    ) {
        self.image = image
        self.screen = screen
        self.screenRect = screenRect
        self.scale = scale
        self.createdAt = createdAt
        self.encoded = encoded
    }

    /// 可直接作为历史库 PNG 复用的数据（仅 PNG 格式内容一致）。
    /// 除扩展名外再校验 PNG 文件签名：扩展名与内容不符的数据不能当作原图入库。
    public var reusablePNGData: Data? {
        guard let encoded, encoded.fileExtension.lowercased() == "png" else { return nil }
        guard encoded.data.count >= pngSignature.count,
              Array(encoded.data.prefix(pngSignature.count)) == pngSignature else { return nil }
        return encoded.data
    }
}

/// PNG 文件签名（8 字节）
private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

public final class CaptureSession {
    public struct Callbacks {
        public var onCopy: (CaptureResult) -> Void
        public var onPin: (CaptureResult) -> Void
        public var onSaved: (CaptureResult, URL) -> Void
        /// 保存写盘失败：会话已结束，宿主必须在此复位自身状态（不能只依赖 onSaved/onCancel）
        public var onSaveFailed: (Error) -> Void
        public var onCancel: () -> Void
        public var onColorPicked: (String) -> Void
        /// 会话已结束（覆盖层已关闭）：宿主必须在此立即释放会话引用。
        /// 写盘等异步收尾可能滞后于会话结束，引用不释放会让后续截图被"会话存在"的判断拦下
        public var onClosed: () -> Void

        public init(
            onCopy: @escaping (CaptureResult) -> Void,
            onPin: @escaping (CaptureResult) -> Void,
            onSaved: @escaping (CaptureResult, URL) -> Void,
            onSaveFailed: @escaping (Error) -> Void,
            onCancel: @escaping () -> Void,
            onColorPicked: @escaping (String) -> Void,
            onClosed: @escaping () -> Void
        ) {
            self.onCopy = onCopy
            self.onPin = onPin
            self.onSaved = onSaved
            self.onSaveFailed = onSaveFailed
            self.onCancel = onCancel
            self.onColorPicked = onColorPicked
            self.onClosed = onClosed
        }
    }

    public let mode: CaptureInteractionMode
    private let capturedScreens: [CapturedScreen]
    private let callbacks: Callbacks
    private let previousApplication = NSWorkspace.shared.frontmostApplication

    private var windows: [OverlayWindow] = []
    private var canvases: [SelectionCanvasView] = []
    private weak var activeCanvas: SelectionCanvasView?
    private var resignObserver: NSObjectProtocol?
    private var isPresentingPanel = false
    private var isClosed = false
    private var savePanel: NSSavePanel?

    public init(
        capturedScreens: [CapturedScreen],
        mode: CaptureInteractionMode,
        callbacks: Callbacks
    ) {
        self.capturedScreens = capturedScreens
        self.mode = mode
        self.callbacks = callbacks
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    public func start() {
        guard !isClosed, !capturedScreens.isEmpty else { return }

        for captured in capturedScreens {
            let window = OverlayWindow(
                contentRect: captured.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: captured.screen
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true
            window.appearance = NSAppearance(named: .darkAqua)

            let container = NSView(frame: NSRect(origin: .zero, size: captured.frame.size))
            container.autoresizingMask = [.width, .height]
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.cgColor

            let baseView = BaseImageView(frame: container.bounds)
            baseView.image = captured.image
            baseView.autoresizingMask = [.width, .height]
            container.addSubview(baseView)

            let canvas = SelectionCanvasView(captured: captured, mode: mode)
            canvas.session = self
            canvas.frame = container.bounds
            canvas.autoresizingMask = [.width, .height]
            container.addSubview(canvas)

            window.contentView = container

            windows.append(window)
            canvases.append(canvas)
        }

        NSApp.activate()
        for window in windows {
            window.orderFrontRegardless()
        }
        let mousePoint = NSEvent.mouseLocation
        let initial = canvases.first(where: { $0.captured.screen.frame.contains(mousePoint) }) ?? canvases.first
        if let initial, let window = initial.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(initial)
            activeCanvas = initial
            initial.updatePointerFromSystem()
        }
        NSCursor.crosshair.set()

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isClosed, !self.isPresentingPanel else { return }
            self.cancel()
        }
    }

    public func activate(canvas: SelectionCanvasView) {
        guard !isClosed else { return }
        activeCanvas = canvas
        guard let window = canvas.window else { return }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            // 程序化创建的覆盖窗没有 initialFirstResponder：不显式指定，键盘事件不会进入画布
            window.makeFirstResponder(canvas)
            canvas.updatePointerFromSystem()
        }
    }

    public func canvasRequestCopy(_ canvas: SelectionCanvasView) {
        guard !isClosed else { return }
        guard let result = composeResult(from: canvas) else {
            canvas.showToast("合成截图失败，请调整选区后重试")
            return
        }
        close()
        callbacks.onCopy(result)
    }

    public func canvasRequestPin(_ canvas: SelectionCanvasView) {
        guard !isClosed else { return }
        guard let result = composeResult(from: canvas) else {
            canvas.showToast("合成截图失败，请调整选区后重试")
            return
        }
        close()
        callbacks.onPin(result)
    }

    public func canvasRequestSave(_ canvas: SelectionCanvasView) {
        guard !isClosed, !isPresentingPanel, let window = canvas.window else { return }
        guard let result = composeResult(from: canvas) else {
            canvas.showToast("合成截图失败，请调整选区后重试")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = ImageExporter.displayFileName(
            fileExtension: AppSettings.shared.saveFormat.fileExtension
        )
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.title = "保存截图"
        panel.prompt = "保存"
        let directory = AppSettings.shared.saveDirectory
        try? SecureFileWriter.ensureDirectory(at: directory)
        panel.directoryURL = directory

        savePanel = panel
        isPresentingPanel = true
        // 闭包强捕获 panel：实测 NSSavePanel 在 sheet 结束后会释放 completionHandler，
        // panel → handler → panel 不构成保留环（v1.3 台账曾误判，已更正）。
        // 强捕获是必要的：会话若在 sheet 期间提前关闭，savePanel 会被置空，
        // 此时只有闭包里的 panel 还能给出 URL，否则保存会静默失效。
        panel.beginSheetModal(for: window) { [weak self, weak canvas, weak window] response in
            guard let self else { return }
            self.isPresentingPanel = false
            guard let canvas, let window else {
                self.savePanel = nil
                return
            }
            if response == .OK, let url = panel.url {
                // 先结束会话再写盘：写盘期间保持可交互会让取消/继续编辑静默覆盖保存结果；
                // 成败都必须回调宿主，否则会话对象会滞留在控制器里导致后续截图失效
                let image = result.image
                let callbacks = self.callbacks
                self.close()
                DispatchQueue.global(qos: .userInitiated).async {
                    let failure: Error?
                    var saved = result
                    do {
                        // write 返回已编码数据：历史库复用同一份 PNG，不再二次编码整图
                        let data = try ImageExporter.write(image, to: url, jpegQuality: AppSettings.shared.jpegQuality)
                        saved.encoded = EncodedCapture(data: data, fileExtension: url.pathExtension)
                        failure = nil
                    } catch {
                        failure = error
                    }
                    DispatchQueue.main.async {
                        if let failure {
                            callbacks.onSaveFailed(failure)
                        } else {
                            callbacks.onSaved(saved, url)
                        }
                    }
                }
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(canvas)
            }
            self.savePanel = nil
        }
    }

    public func canvas(_ canvas: SelectionCanvasView, didPickColor hex: String) {
        guard !isClosed else { return }
        close()
        callbacks.onColorPicked(hex)
    }

    public func cancel() {
        guard !isClosed else { return }
        close()
        callbacks.onCancel()
    }

    private func composeResult(from canvas: SelectionCanvasView) -> CaptureResult? {
        guard let prepared = canvas.prepareForExport() else { return nil }
        guard let image = ImageComposer.compose(
            baseImage: canvas.captured.image,
            selectionRect: prepared.selection,
            screenScale: canvas.captured.scale,
            annotations: prepared.annotations
        ) else { return nil }

        let screen = canvas.captured.screen
        let cocoaRect = CGRect(
            x: screen.frame.minX + prepared.selection.minX,
            y: screen.frame.maxY - prepared.selection.maxY,
            width: prepared.selection.width,
            height: prepared.selection.height
        )
        return CaptureResult(
            image: image,
            screen: screen,
            screenRect: cocoaRect,
            scale: canvas.captured.scale
        )
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        // 只有真正显示过覆盖窗才需要把焦点还给原应用
        let hadOverlay = !windows.isEmpty
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        for canvas in canvases {
            canvas.stopEditing()
            canvas.session = nil
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        canvases.removeAll()
        activeCanvas = nil
        savePanel = nil

        if hadOverlay,
           let previousApplication,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: previousApplication)
        }
        // 宿主会在此释放对会话的引用；自持一份，避免 close() 执行期间会话被提前释放
        withExtendedLifetime(self) {
            callbacks.onClosed()
        }
    }
}
