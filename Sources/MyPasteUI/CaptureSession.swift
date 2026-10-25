import AppKit
import MyPasteCore
import UniformTypeIdentifiers

public struct CaptureResult {
    public let image: CGImage
    public let screen: NSScreen
    public let screenRect: CGRect
    public let scale: CGFloat
    public let createdAt: Date

    public init(image: CGImage, screen: NSScreen, screenRect: CGRect, scale: CGFloat, createdAt: Date = Date()) {
        self.image = image
        self.screen = screen
        self.screenRect = screenRect
        self.scale = scale
        self.createdAt = createdAt
    }
}

public final class CaptureSession {
    public struct Callbacks {
        public var onCopy: (CaptureResult) -> Void
        public var onPin: (CaptureResult) -> Void
        public var onSaved: (CaptureResult, URL) -> Void
        public var onCancel: () -> Void
        public var onColorPicked: (String) -> Void

        public init(
            onCopy: @escaping (CaptureResult) -> Void,
            onPin: @escaping (CaptureResult) -> Void,
            onSaved: @escaping (CaptureResult, URL) -> Void,
            onCancel: @escaping () -> Void,
            onColorPicked: @escaping (String) -> Void
        ) {
            self.onCopy = onCopy
            self.onPin = onPin
            self.onSaved = onSaved
            self.onCancel = onCancel
            self.onColorPicked = onColorPicked
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
            canvas.updatePointerFromSystem()
        }
    }

    public func canvasRequestCopy(_ canvas: SelectionCanvasView) {
        guard !isClosed, let result = composeResult(from: canvas) else { return }
        close()
        callbacks.onCopy(result)
    }

    public func canvasRequestPin(_ canvas: SelectionCanvasView) {
        guard !isClosed, let result = composeResult(from: canvas) else { return }
        close()
        callbacks.onPin(result)
    }

    public func canvasRequestSave(_ canvas: SelectionCanvasView) {
        guard !isClosed, !isPresentingPanel, let window = canvas.window else { return }
        guard let result = composeResult(from: canvas) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = ImageExporter.displayFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.title = "保存截图"
        panel.prompt = "保存"
        let directory = AppSettings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        panel.directoryURL = directory

        savePanel = panel
        isPresentingPanel = true
        panel.beginSheetModal(for: window) { [weak self, weak canvas, weak window, weak panel] response in
            guard let self else { return }
            self.isPresentingPanel = false
            self.savePanel = nil
            guard let canvas, let window, let panel else { return }
            if response == .OK, let url = panel.url {
                do {
                    try ImageExporter.write(result.image, to: url)
                    self.close()
                    self.callbacks.onSaved(result, url)
                } catch {
                    self.presentSaveError(error, window: window, canvas: canvas)
                }
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(canvas)
            }
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

    private func presentSaveError(_ error: Error, window: NSWindow, canvas: SelectionCanvasView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in
            window.makeKey()
            window.makeFirstResponder(canvas)
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
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

        if let previousApplication,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: previousApplication)
        }
    }
}
