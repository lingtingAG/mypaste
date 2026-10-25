import AppKit
import MyPasteCore
import UniformTypeIdentifiers

private enum PinCorner {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private enum PinDragState {
    case none
    case moving(initialMouse: CGPoint, initialOrigin: CGPoint)
    case resizing(corner: PinCorner, initialMouse: CGPoint, initialFrame: CGRect)
}

private final class PinWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinContentView: NSView {
    var image: CGImage
    var originalText: String?
    var onClose: (() -> Void)?
    var onHide: (() -> Void)?
    weak var controller: PinWindowController?

    private var isHovering = false
    private var dragState: PinDragState = .none
    private var trackingAreaRef: NSTrackingArea?
    private var hudText: String?
    private var hudWorkItem: DispatchWorkItem?
    private(set) var alwaysOnTop = true

    private let handleSize: CGFloat = 7
    private let handleHitSlop: CGFloat = 9

    init(image: CGImage, originalText: String?) {
        self.image = image
        self.originalText = originalText
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.black.setFill()
        path.fill()
        context.saveGState()
        path.addClip()
        context.interpolationQuality = .high
        AnnotationRenderer.drawImageTopLeft(image, in: bounds, in: context)
        context.restoreGState()

        NSColor.white.withAlphaComponent(isHovering ? 0.55 : 0.22).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()

        if isHovering {
            for rect in cornerRects().values {
                let handlePath = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
                NSColor.white.setFill()
                handlePath.fill()
                NSColor.black.withAlphaComponent(0.4).setStroke()
                handlePath.lineWidth = 1
                handlePath.stroke()
            }
        }

        if let hudText {
            let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let textSize = (hudText as NSString).size(withAttributes: attributes)
            let rect = CGRect(
                x: (bounds.width - textSize.width - 22) / 2,
                y: bounds.height - 34,
                width: textSize.width + 22,
                height: 24
            )
            NSColor(calibratedWhite: 0.06, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (hudText as NSString).draw(
                at: CGPoint(x: rect.minX + 11, y: rect.minY + 5),
                withAttributes: attributes
            )
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            closePin()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let mouse = NSEvent.mouseLocation
        if let corner = cornerHit(point), let frame = window?.frame {
            dragState = .resizing(corner: corner, initialMouse: mouse, initialFrame: frame)
        } else if let frame = window?.frame {
            dragState = .moving(initialMouse: mouse, initialOrigin: frame.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        switch dragState {
        case let .moving(initialMouse, initialOrigin):
            let origin = CGPoint(
                x: initialOrigin.x + (mouse.x - initialMouse.x),
                y: initialOrigin.y + (mouse.y - initialMouse.y)
            )
            window?.setFrameOrigin(origin)

        case let .resizing(corner, initialMouse, initialFrame):
            let aspect = max(0.05, initialFrame.width / max(1, initialFrame.height))
            let dx = mouse.x - initialMouse.x
            let dy = mouse.y - initialMouse.y
            let horizontalDelta: CGFloat = (corner == .topRight || corner == .bottomRight) ? dx : -dx
            let verticalDelta: CGFloat = (corner == .topLeft || corner == .topRight) ? dy * aspect : -dy * aspect
            let useHorizontal = abs(horizontalDelta) >= abs(verticalDelta)
            let targetWidth = initialFrame.width + (useHorizontal ? horizontalDelta : verticalDelta)
            let newWidth = min(max(40, targetWidth), 8000)
            let newHeight = newWidth / aspect

            var origin = initialFrame.origin
            switch corner {
            case .bottomRight:
                origin = CGPoint(x: initialFrame.minX, y: initialFrame.maxY - newHeight)
            case .bottomLeft:
                origin = CGPoint(x: initialFrame.maxX - newWidth, y: initialFrame.maxY - newHeight)
            case .topRight:
                origin = CGPoint(x: initialFrame.minX, y: initialFrame.minY)
            case .topLeft:
                origin = CGPoint(x: initialFrame.maxX - newWidth, y: initialFrame.minY)
            }
            window?.setFrame(CGRect(x: origin.x, y: origin.y, width: newWidth, height: newHeight), display: true)

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragState = .none
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.option) {
            let step = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
            let newAlpha = min(1, max(0.15, window.alphaValue + step))
            window.alphaValue = newAlpha
            flash("不透明度 \(Int((newAlpha * 100).rounded()))%")
            return
        }

        let raw = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08)
        let factor = min(1.35, max(0.7, exp(raw)))
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        let anchorX = (mouse.x - frame.minX) / max(1, frame.width)
        let anchorY = (mouse.y - frame.minY) / max(1, frame.height)
        let aspect = max(0.05, frame.width / max(1, frame.height))
        let newWidth = min(max(40, frame.width * factor), 12000)
        let newHeight = newWidth / aspect
        let origin = CGPoint(
            x: mouse.x - anchorX * newWidth,
            y: mouse.y - anchorY * newHeight
        )
        window.setFrame(CGRect(x: origin.x, y: origin.y, width: newWidth, height: newHeight), display: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let menu = makeContextMenu()
        let point = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 51 {
            closePin()
            return
        }
        if event.modifierFlags.contains(.command) {
            switch (event.charactersIgnoringModifiers ?? "").lowercased() {
            case "c":
                copyForUser()
                return
            case "s":
                saveImage()
                return
            case "w":
                closePin()
                return
            default:
                break
            }
        }
        if [123, 124, 125, 126].contains(Int(event.keyCode)) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var origin = window?.frame.origin ?? .zero
            switch event.keyCode {
            case 123: origin.x -= step
            case 124: origin.x += step
            case 125: origin.y -= step
            case 126: origin.y += step
            default: break
            }
            window?.setFrameOrigin(origin)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Cursor / corners

    private func cornerRects() -> [PinCorner: CGRect] {
        let size = handleSize
        return [
            .topLeft: CGRect(x: 1, y: 1, width: size, height: size),
            .topRight: CGRect(x: bounds.width - size - 1, y: 1, width: size, height: size),
            .bottomLeft: CGRect(x: 1, y: bounds.height - size - 1, width: size, height: size),
            .bottomRight: CGRect(x: bounds.width - size - 1, y: bounds.height - size - 1, width: size, height: size),
        ]
    }

    private func cornerHit(_ point: CGPoint) -> PinCorner? {
        for (corner, rect) in cornerRects() {
            if rect.insetBy(dx: -handleHitSlop, dy: -handleHitSlop).contains(point) {
                return corner
            }
        }
        return nil
    }

    private func updateCursor(at point: CGPoint) {
        if cornerHit(point) != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    // MARK: - Actions

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let copy = NSMenuItem(title: originalText == nil ? "复制图片" : "复制文本", action: #selector(copyForUser), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        if originalText != nil {
            let copyImage = NSMenuItem(title: "复制图片", action: #selector(copyImageOnly), keyEquivalent: "")
            copyImage.target = self
            menu.addItem(copyImage)
        }
        let save = NSMenuItem(title: "保存图片…", action: #selector(saveImage), keyEquivalent: "s")
        save.target = self
        menu.addItem(save)
        menu.addItem(.separator())

        let zoomMenu = NSMenu()
        let actualSize = NSMenuItem(title: "实际大小", action: #selector(resetZoom), keyEquivalent: "")
        actualSize.target = self
        zoomMenu.addItem(actualSize)
        for percent in [50, 200] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(zoomPercent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            zoomMenu.addItem(item)
        }
        let fit = NSMenuItem(title: "适应屏幕", action: #selector(fitToScreen), keyEquivalent: "")
        fit.target = self
        zoomMenu.addItem(fit)
        let zoomItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = abs((window?.alphaValue ?? 1) * 100 - CGFloat(percent)) < 1 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let onTop = NSMenuItem(title: "始终置顶", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = alwaysOnTop ? .on : .off
        menu.addItem(onTop)
        menu.addItem(.separator())

        let info = NSMenuItem(
            title: "\(image.width) × \(image.height) px",
            action: nil,
            keyEquivalent: ""
        )
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        let hide = NSMenuItem(title: "隐藏贴图", action: #selector(hidePin), keyEquivalent: "h")
        hide.target = self
        menu.addItem(hide)
        let close = NSMenuItem(title: "关闭贴图", action: #selector(closePin), keyEquivalent: "\u{1b}")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc func copy(_ sender: Any?) {
        copyForUser()
    }

    @objc func copyForUser() {
        if let originalText {
            PasteboardWriter.writeText(originalText)
            flash("已复制文本")
        } else {
            PasteboardWriter.writeImage(image)
            flash("已复制图片")
        }
        playSound()
    }

    @objc private func copyImageOnly() {
        PasteboardWriter.writeImage(image)
        flash("已复制图片")
        playSound()
    }

    @objc func saveImage() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = ImageExporter.displayFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = AppSettings.shared.saveDirectory
        try? FileManager.default.createDirectory(
            at: AppSettings.shared.saveDirectory,
            withIntermediateDirectories: true
        )
        NSApp.activate()
        panel.beginSheetModal(for: window) { [weak self, weak window, weak panel] response in
            guard let self, let window, let panel else { return }
            if response == .OK, let url = panel.url {
                do {
                    try ImageExporter.write(self.image, to: url)
                    self.flash("已保存")
                    self.playSound()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "保存失败"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window)
                }
            }
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }

    @objc private func resetZoom() {
        guard let window else { return }
        guard let controller else { return }
        let size = controller.initialDisplaySize
        window.setFrame(CGRect(origin: window.frame.origin, size: size), display: true)
    }

    @objc private func zoomPercent(_ sender: NSMenuItem) {
        guard let window, let controller else { return }
        let factor = CGFloat(sender.tag) / 100
        let size = CGSize(
            width: controller.initialDisplaySize.width * factor,
            height: controller.initialDisplaySize.height * factor
        )
        var frame = CGRect(origin: window.frame.origin, size: size)
        frame.origin.y = window.frame.maxY - size.height
        window.setFrame(frame, display: true)
    }

    @objc private func fitToScreen() {
        guard let window else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        let aspect = window.frame.width / max(1, window.frame.height)
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        let origin = CGPoint(
            x: available.midX - width / 2,
            y: available.midY - height / 2
        )
        window.setFrame(CGRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
        flash("不透明度 \(sender.tag)%")
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        window?.level = alwaysOnTop ? .floating : .normal
        flash(alwaysOnTop ? "已置顶" : "已取消置顶")
    }

    @objc private func hidePin() {
        onHide?()
        flash("已隐藏，可在菜单栏“显示全部贴图”中恢复")
    }

    @objc func closePin() {
        dragState = .none
        if let onClose {
            onClose()
        } else {
            controller?.closePin()
        }
    }

    func flash(_ message: String) {
        hudText = message
        needsDisplay = true
        hudWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hudText = nil
            self?.needsDisplay = true
        }
        hudWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func playSound() {
        guard AppSettings.shared.playSound else { return }
        NSSound(named: "Tink")?.play()
    }

    func updateAlwaysOnTop(_ value: Bool) {
        alwaysOnTop = value
        window?.level = value ? .floating : .normal
    }
}

public final class PinWindowController: NSWindowController, NSWindowDelegate {
    public private(set) var image: CGImage
    public let initialDisplaySize: CGSize
    public let originalText: String?
    var onCloseRequested: ((PinWindowController) -> Void)?
    var onHideRequested: ((PinWindowController) -> Void)?
    private var didRequestClose = false

    private let content: PinContentView

    init(image: CGImage, frame: CGRect, originalText: String?) {
        self.image = image
        self.initialDisplaySize = frame.size
        self.originalText = originalText
        let panel = PinWindow(
            contentRect: CGRect(origin: .zero, size: frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let view = PinContentView(image: image, originalText: originalText)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        self.content = view
        super.init(window: panel)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        view.controller = self
        view.onClose = { [weak self] in
            self?.closePin()
        }
        view.onHide = { [weak self, weak panel] in
            guard let self else { return }
            panel?.orderOut(nil)
            self.onHideRequested?(self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        window?.orderFrontRegardless()
    }

    public func showWindowIfHidden() {
        window?.orderFrontRegardless()
    }

    public func orderOut() {
        window?.orderOut(nil)
    }

    public func closePin() {
        guard !didRequestClose else { return }
        didRequestClose = true
        guard let window else {
            onCloseRequested?(self)
            return
        }
        window.orderOut(nil)
        window.close()
        onCloseRequested?(self)
    }

    public func windowWillClose(_ notification: Notification) {
        guard !didRequestClose else { return }
        didRequestClose = true
        onCloseRequested?(self)
    }
}
