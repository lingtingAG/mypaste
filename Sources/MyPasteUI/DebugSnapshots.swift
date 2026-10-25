import AppKit
import CoreGraphics
import MyPasteCore

public enum DebugSnapshots {
    @MainActor
    public static func renderStudio(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canvasSize = CGSize(width: 1440, height: 900)
        guard let desktop = makeDesktopImage(size: canvasSize, scale: 2) else {
            throw NSError(domain: "MyPasteSnapshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法生成桌面底图"])
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let captured = CapturedScreen(screen: screen, image: desktop, scale: 2)
        var outputs: [URL] = []

        try write(desktop, name: "00-desktop.png", to: directory, outputs: &outputs)

        let codeWindow = CGRect(x: 420, y: 222, width: 820, height: 546)
        let selection = CGRect(x: 472, y: 252, width: 720, height: 424)

        let annotations: [Annotation] = [
            Annotation(kind: .number(center: CGPoint(x: 46, y: 34), value: 1), color: .red, lineWidth: 4),
            Annotation(kind: .rectangle(CGRect(x: 78, y: 64, width: 304, height: 74)), color: .red, lineWidth: 4),
            Annotation(kind: .arrow(from: CGPoint(x: 398, y: 112), to: CGPoint(x: 478, y: 176)), color: .orange, lineWidth: 5),
            Annotation(kind: .text(origin: CGPoint(x: 492, y: 158), string: "这里需要补一个临时变量", fontSize: 18), color: .red, lineWidth: 4),
            Annotation(kind: .mosaic(CGRect(x: 52, y: 196, width: 250, height: 66)), color: .red, lineWidth: 5),
            Annotation(kind: .blur(CGRect(x: 322, y: 196, width: 222, height: 66)), color: .red, lineWidth: 5),
            Annotation(kind: .marker(points: [
                CGPoint(x: 84, y: 272), CGPoint(x: 208, y: 268), CGPoint(x: 332, y: 272), CGPoint(x: 458, y: 268),
            ]), color: .yellow, lineWidth: 9),
            Annotation(kind: .pen(points: [
                CGPoint(x: 512, y: 272), CGPoint(x: 520, y: 258), CGPoint(x: 530, y: 286),
                CGPoint(x: 542, y: 258), CGPoint(x: 554, y: 286), CGPoint(x: 566, y: 270),
            ]), color: .purple, lineWidth: 3),
            Annotation(kind: .ellipse(CGRect(x: 440, y: 318, width: 154, height: 78)), color: .green, lineWidth: 4),
        ]

        if let hoverImage = renderOverlay(
            captured: captured,
            size: canvasSize,
            mode: .edit,
            configure: { canvas in
                canvas.configureForSnapshot(
                    selection: nil,
                    annotations: [],
                    tool: .move,
                    color: .red,
                    lineWidth: 4,
                    filled: false,
                    cursor: CGPoint(x: 760, y: 490),
                    hoveredWindow: DetectedWindow(
                        windowID: 42,
                        ownerName: "Code",
                        windowName: "SelectionCanvasView.swift",
                        localRect: codeWindow,
                        cocoaRect: .zero
                    ),
                    withToolbar: false
                )
            }
        ) {
            try write(hoverImage, name: "01-overlay-hover.png", to: directory, outputs: &outputs)
        }

        if let editorImage = renderOverlay(
            captured: captured,
            size: canvasSize,
            mode: .edit,
            configure: { canvas in
                canvas.configureForSnapshot(
                    selection: selection,
                    annotations: annotations,
                    tool: .rectangle,
                    color: .red,
                    lineWidth: 4,
                    filled: false,
                    cursor: CGPoint(x: 1240, y: 722),
                    hoveredWindow: nil,
                    withToolbar: true
                )
            }
        ) {
            try write(editorImage, name: "02-overlay-editor.png", to: directory, outputs: &outputs)
        }

        if let textEditorImage = renderOverlay(
            captured: captured,
            size: canvasSize,
            mode: .edit,
            configure: { canvas in
                canvas.configureForSnapshot(
                    selection: selection,
                    annotations: [],
                    tool: .text,
                    color: .red,
                    lineWidth: 4,
                    filled: false,
                    cursor: nil,
                    hoveredWindow: nil,
                    withToolbar: true,
                    fontSize: 24,
                    textEditing: SnapshotTextEditing(
                        origin: CGPoint(x: 166, y: 210),
                        text: "输入文字后可直接拖动这段文字",
                        fontSize: 24
                    )
                )
            }
        ) {
            try write(textEditorImage, name: "10-text-editor.png", to: directory, outputs: &outputs)
        }

        if let pickerImage = renderOverlay(
            captured: captured,
            size: canvasSize,
            mode: .colorPicker,
            configure: { canvas in
                canvas.configureForSnapshot(
                    selection: nil,
                    annotations: [],
                    tool: .move,
                    color: .red,
                    lineWidth: 4,
                    filled: false,
                    cursor: CGPoint(x: 300, y: 700),
                    hoveredWindow: nil,
                    withToolbar: false
                )
            }
        ) {
            try write(pickerImage, name: "03-overlay-colorpicker.png", to: directory, outputs: &outputs)
        }

        if let composed = ImageComposer.compose(
            baseImage: desktop,
            selectionRect: selection,
            screenScale: 2,
            annotations: annotations
        ) {
            try write(composed, name: "04-composition.png", to: directory, outputs: &outputs)
        }

        if let textCard = ClipboardCard.make(from: "Snipaste 风格的贴图文本示例。\n支持中英文混排、自动换行，以及从剪贴板直接贴图。\nF1 截图 · F3 贴图") {
            try write(textCard.image, name: "05-card-text.png", to: directory, outputs: &outputs)
        }
        if let colorCard = ClipboardCard.makeColorCard(color: .blue, rawText: "#0A84FF") {
            try write(colorCard.image, name: "06-card-color.png", to: directory, outputs: &outputs)
        }

        try renderPinPreview(desktop: desktop, directory: directory, outputs: &outputs)
        try renderPreferences(directory: directory, outputs: &outputs)
        try renderHistory(desktop: desktop, directory: directory, outputs: &outputs)

        return outputs
    }

    // MARK: - Overlay

    @MainActor
    private static func renderOverlay(
        captured: CapturedScreen,
        size: CGSize,
        mode: CaptureInteractionMode,
        configure: (SelectionCanvasView) -> Void
    ) -> CGImage? {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let base = BaseImageView(frame: container.bounds)
        base.image = captured.image
        container.addSubview(base)

        let canvas = SelectionCanvasView(captured: captured, mode: mode)
        canvas.frame = container.bounds
        container.addSubview(canvas)
        window.contentView = container
        configure(canvas)
        container.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()

        let image = cache(view: container)
        window.close()
        return image
    }

    // MARK: - Pin / Preferences / History

    @MainActor
    private static func renderPinPreview(desktop: CGImage, directory: URL, outputs: inout [URL]) throws {
        let cropRect = CGRect(x: 840, y: 444, width: 1640, height: 1092)
        guard let crop = desktop.cropping(to: cropRect) else { return }
        let pinSize = CGSize(width: 660, height: 440)
        let controller = PinWindowController(
            image: crop,
            frame: CGRect(origin: .zero, size: pinSize),
            originalText: nil
        )
        guard let contentView = controller.window?.contentView else { return }
        contentView.appearance = NSAppearance(named: .darkAqua)
        contentView.layoutSubtreeIfNeeded()
        guard let pinImage = cache(view: contentView) else { return }

        let canvasSize = CGSize(width: 1080, height: 640)
        guard let backdrop = desktop.cropping(to: CGRect(x: 600, y: 480, width: 2160, height: 1280)),
              let composed = OffscreenRenderer.render(size: canvasSize, scale: 2, draw: { context in
                  AnnotationRenderer.drawImageTopLeft(backdrop, in: CGRect(origin: .zero, size: canvasSize), in: context)
                  NSColor.black.withAlphaComponent(0.25).setFill()
                  NSRect(origin: .zero, size: canvasSize).fill()
                  let pinRect = CGRect(x: 230, y: 120, width: pinSize.width, height: pinSize.height)
                  context.saveGState()
                  context.setShadow(offset: CGSize(width: 0, height: 18), blur: 42, color: NSColor.black.withAlphaComponent(0.55).cgColor)
                  NSColor.black.withAlphaComponent(0.9).setFill()
                  NSBezierPath(roundedRect: pinRect, xRadius: 4, yRadius: 4).fill()
                  context.restoreGState()
                  AnnotationRenderer.drawImageTopLeft(pinImage, in: pinRect, in: context)
              }) else { return }
        try write(composed, name: "07-pin.png", to: directory, outputs: &outputs)
        controller.window?.close()
    }

    @MainActor
    private static func renderPreferences(directory: URL, outputs: inout [URL]) throws {
        let suiteName = "com.mypaste.snapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.captureShortcut = .capture
        settings.pinShortcut = .pin
        settings.fullScreenShortcut = .fullScreen
        let controller = PreferencesWindowController(settings: settings, onHotkeysChanged: { [] })
        guard let view = controller.makeSnapshotContentView(), let image = cache(view: view) else { return }
        try write(image, name: "08-preferences.png", to: directory, outputs: &outputs)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    private static func renderHistory(desktop: CGImage, directory: URL, outputs: inout [URL]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteSnapshotHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let crops: [CGRect] = [
            CGRect(x: 320, y: 440, width: 2200, height: 1400),
            CGRect(x: 1400, y: 600, width: 2600, height: 1640),
            CGRect(x: 480, y: 1200, width: 1800, height: 1120),
            CGRect(x: 1800, y: 1000, width: 2000, height: 1240),
            CGRect(x: 960, y: 720, width: 2800, height: 1800),
            CGRect(x: 2400, y: 600, width: 1600, height: 1040),
            CGRect(x: 600, y: 600, width: 1520, height: 1000),
        ]
        for rect in crops {
            if let image = desktop.cropping(to: rect) {
                _ = try? store.recordSync(image, limit: 50)
            }
        }
        let controller = HistoryWindowController(store: store, pinBoard: PinBoard())
        guard let view = controller.makeSnapshotContentView(), let image = cache(view: view) else { return }
        try write(image, name: "09-history.png", to: directory, outputs: &outputs)
    }

    // MARK: - Rendering helpers

    @MainActor
    private static func cache(view: NSView) -> CGImage? {
        guard view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        NSLog("Snapshot cached %@ at %dx%d", NSStringFromRect(view.bounds), representation.pixelsWide, representation.pixelsHigh)
        return representation.cgImage
    }

    private static func write(_ image: CGImage, name: String, to directory: URL, outputs: inout [URL]) throws {
        guard let data = ImageExporter.pngData(image) else {
            throw NSError(domain: "MyPasteSnapshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        outputs.append(url)
    }

    // MARK: - Fake desktop

    static func makeDesktopImage(size: CGSize, scale: CGFloat) -> CGImage? {
        OffscreenRenderer.render(size: size, scale: scale) { context in
            let bounds = CGRect(origin: .zero, size: size)
            let colors = [
                NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.19, alpha: 1),
                NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.31, alpha: 1),
                NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.32, alpha: 1),
                NSColor(calibratedRed: 0.70, green: 0.32, blue: 0.23, alpha: 1),
            ]
            NSGradient(colors: colors)?.draw(in: bounds, angle: -36)

            drawBlob(rect: CGRect(x: 60, y: 500, width: 560, height: 560), color: NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.95, alpha: 0.45), context: context)
            drawBlob(rect: CGRect(x: 900, y: -120, width: 620, height: 620), color: NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.3, alpha: 0.32), context: context)
            drawBlob(rect: CGRect(x: 500, y: 250, width: 500, height: 500), color: NSColor(calibratedRed: 0.8, green: 0.25, blue: 0.6, alpha: 0.22), context: context)

            drawMenuBar(size: size)

            drawBrowserWindow(rect: CGRect(x: 72, y: 132, width: 604, height: 560))
            drawCodeWindow(rect: CGRect(x: 420, y: 222, width: 820, height: 546))
            drawTerminalWindow(rect: CGRect(x: 1050, y: 540, width: 320, height: 250))
            drawDock(size: size)
        }
    }

    private static func drawBlob(rect: CGRect, color: NSColor, context: CGContext) {
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        let gradient = NSGradient(colors: [color, color.withAlphaComponent(0)])
        gradient?.draw(in: rect, relativeCenterPosition: .zero)
        context.restoreGState()
    }

    private static func drawMenuBar(size: CGSize) {
        let bar = CGRect(x: 0, y: 0, width: size.width, height: 27)
        NSColor.black.withAlphaComponent(0.22).setFill()
        bar.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        ("  Finder   文件   编辑   显示   前往   窗口   帮助" as NSString).draw(
            at: CGPoint(x: 16, y: 7),
            withAttributes: attributes
        )
        let right = "10:09  ◉  ▮▮  ⌁"
        let rightSize = (right as NSString).size(withAttributes: attributes)
        (right as NSString).draw(
            at: CGPoint(x: size.width - rightSize.width - 20, y: 7),
            withAttributes: attributes
        )
    }

    private static func drawBrowserWindow(rect: CGRect) {
        dropShadow(rect: rect, radius: 28)
        let window = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
        window.fill()
        resetShadow()

        let toolbar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 44)
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: toolbar, xRadius: 11, yRadius: 11).fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        CGRect(x: rect.minX, y: rect.minY + 30, width: rect.width, height: 14).fill()
        drawTrafficLights(origin: CGPoint(x: rect.minX + 16, y: rect.minY + 18))
        let address = CGRect(x: rect.minX + 72, y: rect.minY + 11, width: rect.width - 148, height: 22)
        NSColor.white.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: address, xRadius: 5, yRadius: 5).fill()
        drawText("snipaste.com", at: CGPoint(x: address.minX + 9, y: address.minY + 4), font: .systemFont(ofSize: 10.5), color: NSColor(calibratedWhite: 0.35, alpha: 1))

        let content = CGRect(x: rect.minX, y: rect.minY + 44, width: rect.width, height: rect.height - 44)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        content.fill()
        let hero = CGRect(x: content.minX + 26, y: content.minY + 26, width: content.width - 52, height: 116)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.88, green: 0.94, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.96, green: 0.88, blue: 0.9, alpha: 1),
        ])?.draw(in: NSBezierPath(roundedRect: hero, xRadius: 8, yRadius: 8), angle: 30)
        drawText("截图 · 贴图 · 标注", at: CGPoint(x: hero.minX + 22, y: hero.minY + 22), font: .systemFont(ofSize: 22, weight: .semibold), color: NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.25, alpha: 1))
        drawText("A native macOS screenshot utility", at: CGPoint(x: hero.minX + 22, y: hero.minY + 54), font: .systemFont(ofSize: 11), color: NSColor(calibratedWhite: 0.4, alpha: 1))
        let button = CGRect(x: hero.minX + 22, y: hero.minY + 76, width: 92, height: 24)
        NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6).fill()
        drawText("下载", at: CGPoint(x: button.minX + 31, y: button.minY + 4), font: .systemFont(ofSize: 11, weight: .medium), color: .white)

        for index in 0..<3 {
            let card = CGRect(x: content.minX + 26 + CGFloat(index) * 180, y: content.minY + 164, width: 166, height: 138)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7).fill()
            NSColor(calibratedWhite: 0.3, alpha: 0.12).setStroke()
            let border = NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7)
            border.lineWidth = 1
            border.stroke()
            let thumbColors = [NSColor.systemOrange, NSColor.systemPurple, NSColor.systemTeal]
            thumbColors[index].withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: CGRect(x: card.minX + 10, y: card.minY + 10, width: card.width - 20, height: 74), xRadius: 5, yRadius: 5).fill()
            drawFakeLines(in: CGRect(x: card.minX + 10, y: card.minY + 94, width: card.width - 20, height: 32), color: NSColor(calibratedWhite: 0.68, alpha: 1), lineHeight: 8, gap: 6, widths: [0.9, 0.6])
        }
        for index in 0..<2 {
            let line = CGRect(x: content.minX + 26, y: content.minY + 326 + CGFloat(index) * 18, width: content.width - 52 - CGFloat(index) * 80, height: 7)
            NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
            NSBezierPath(roundedRect: line, xRadius: 3.5, yRadius: 3.5).fill()
        }
    }

    private static func drawCodeWindow(rect: CGRect) {
        dropShadow(rect: rect, radius: 34)
        NSColor(calibratedRed: 0.105, green: 0.11, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        resetShadow()

        let titleBar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 38)
        NSColor(calibratedRed: 0.13, green: 0.135, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: titleBar, xRadius: 10, yRadius: 10).fill()
        NSColor(calibratedRed: 0.13, green: 0.135, blue: 0.17, alpha: 1).setFill()
        CGRect(x: titleBar.minX, y: titleBar.maxY - 12, width: titleBar.width, height: 12).fill()
        drawTrafficLights(origin: CGPoint(x: rect.minX + 16, y: rect.minY + 15))
        drawText("SelectionCanvasView.swift", at: CGPoint(x: rect.midX - 72, y: rect.minY + 11), font: .systemFont(ofSize: 11, weight: .medium), color: NSColor.white.withAlphaComponent(0.5))

        let sidebar = CGRect(x: rect.minX, y: rect.minY + 38, width: 172, height: rect.height - 38)
        NSColor(calibratedRed: 0.125, green: 0.13, blue: 0.16, alpha: 1).setFill()
        sidebar.fill()
        let sidebarItems = ["Explorer", "MyPaste", "Sources", "  MyPasteCore", "  MyPasteUI", "    Overlay", "    Pin", "Tests", "Package.swift"]
        for (index, item) in sidebarItems.enumerated() {
            let color = index == 0 ? NSColor.white.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.62)
            drawText(item, at: CGPoint(x: sidebar.minX + 14, y: sidebar.minY + 14 + CGFloat(index) * 24), font: NSFont.systemFont(ofSize: 10.5, weight: index == 0 ? .semibold : .regular), color: color)
        }

        let editor = CGRect(x: sidebar.maxX, y: rect.minY + 38, width: rect.width - sidebar.width, height: rect.height - 38)
        NSColor(calibratedRed: 0.095, green: 0.10, blue: 0.13, alpha: 1).setFill()
        editor.fill()
        let codeLines: [(String, NSColor)] = [
            ("import AppKit", NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.95, alpha: 1)),
            ("import MyPasteCore", NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.95, alpha: 1)),
            ("", .clear),
            ("final class SelectionCanvasView: NSView {", NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.52, alpha: 1)),
            ("    private var selection: CGRect?", NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.96, alpha: 1)),
            ("    private var annotations: [Annotation] = []", NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.96, alpha: 1)),
            ("    private(set) var tool: Tool = .move", NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.96, alpha: 1)),
            ("", .clear),
            ("    func drawSelection() {", NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.62, alpha: 1)),
            ("        guard let selection else { return }", NSColor(calibratedRed: 0.92, green: 0.72, blue: 0.48, alpha: 1)),
            ("        context.clip(to: selection)", NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)),
            ("        AnnotationRenderer.draw(annotations)", NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)),
            ("        drawSizeBadge(selection)", NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)),
            ("    }", NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.62, alpha: 1)),
            ("", .clear),
            ("    func finish(_ action: FinishAction) {", NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.62, alpha: 1)),
            ("        switch action {", NSColor(calibratedRed: 0.92, green: 0.72, blue: 0.48, alpha: 1)),
            ("        case .copy:  copyToPasteboard()", NSColor(calibratedRed: 0.72, green: 0.86, blue: 0.60, alpha: 1)),
            ("        case .pin:   pinToScreen()", NSColor(calibratedRed: 0.72, green: 0.86, blue: 0.60, alpha: 1)),
            ("        case .save:  presentSavePanel()", NSColor(calibratedRed: 0.72, green: 0.86, blue: 0.60, alpha: 1)),
            ("        }", NSColor(calibratedRed: 0.92, green: 0.72, blue: 0.48, alpha: 1)),
            ("    }", NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.62, alpha: 1)),
            ("}", NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.52, alpha: 1)),
        ]
        NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 0.8).setFill()
        CGRect(x: editor.minX + 14, y: editor.minY + 84, width: editor.width - 28, height: 22).fill()
        for (index, line) in codeLines.enumerated() {
            let y = editor.minY + 20 + CGFloat(index) * 19
            drawText(String(format: "%02d", index + 1), at: CGPoint(x: editor.minX + 14, y: y), font: .monospacedSystemFont(ofSize: 9.5, weight: .regular), color: NSColor.white.withAlphaComponent(0.2))
            if !line.0.isEmpty {
                drawText(line.0, at: CGPoint(x: editor.minX + 48, y: y), font: .monospacedSystemFont(ofSize: 10.5, weight: .regular), color: line.1)
            }
        }
        let minimap = CGRect(x: editor.maxX - 74, y: editor.minY + 14, width: 52, height: editor.height - 28)
        NSColor.white.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: minimap, xRadius: 3, yRadius: 3).fill()
        for index in 0..<27 {
            let width = minimap.width * CGFloat([0.7, 0.4, 0.9, 0.55][index % 4])
            NSColor.white.withAlphaComponent(0.13).setFill()
            CGRect(x: minimap.minX + 6, y: minimap.minY + 8 + CGFloat(index) * 6, width: width - 8, height: 2).fill()
        }
    }

    private static func drawTerminalWindow(rect: CGRect) {
        dropShadow(rect: rect, radius: 24)
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.09, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        resetShadow()
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 30), xRadius: 9, yRadius: 9).fill()
        drawTrafficLights(origin: CGPoint(x: rect.minX + 14, y: rect.minY + 11))
        drawText("zsh — 120×32", at: CGPoint(x: rect.midX - 40, y: rect.minY + 8), font: .systemFont(ofSize: 9.5, weight: .medium), color: NSColor.white.withAlphaComponent(0.35))
        let lines = [
            "❯ swift build -c release",
            "Building for production...",
            "Build complete! (7.42s)",
            "❯ ps -o rss= -p $(pgrep MyPaste)",
            "  28716",
            "❯ open build/MyPaste.app",
        ]
        let colors: [NSColor] = [.white, NSColor.white.withAlphaComponent(0.45), .systemGreen, .white, .systemYellow, .white]
        for (index, line) in lines.enumerated() {
            drawText(line, at: CGPoint(x: rect.minX + 14, y: rect.minY + 48 + CGFloat(index) * 22), font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: colors[index])
        }
        NSColor.systemGreen.withAlphaComponent(0.8).setFill()
        CGRect(x: rect.minX + 14, y: rect.minY + 48 + CGFloat(lines.count) * 22, width: 7, height: 13).fill()
    }

    private static func drawDock(size: CGSize) {
        let dockWidth: CGFloat = 536
        let dock = CGRect(x: (size.width - dockWidth) / 2, y: size.height - 88, width: dockWidth, height: 68)
        NSColor.white.withAlphaComponent(0.12).setFill()
        let path = NSBezierPath(roundedRect: dock, xRadius: 18, yRadius: 18)
        path.fill()
        NSColor.white.withAlphaComponent(0.09).setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbols = ["safari", "message.fill", "envelope.fill", "calendar", "note.text", "photo", "music.note", "terminal.fill", "gearshape.fill"]
        let gradients: [(NSColor, NSColor)] = [
            (NSColor.systemBlue, NSColor.systemCyan),
            (NSColor.systemGreen, NSColor.systemMint),
            (NSColor.systemBlue, NSColor.systemIndigo),
            (NSColor.systemRed, NSColor.white),
            (NSColor.systemYellow, NSColor.systemOrange),
            (NSColor.systemTeal, NSColor.systemBlue),
            (NSColor.systemPink, NSColor.systemRed),
            (NSColor(calibratedWhite: 0.15, alpha: 1), NSColor(calibratedWhite: 0.35, alpha: 1)),
            (NSColor(calibratedWhite: 0.55, alpha: 1), NSColor(calibratedWhite: 0.8, alpha: 1)),
        ]
        for index in 0..<symbols.count {
            let rect = CGRect(x: dock.minX + 14 + CGFloat(index) * 56, y: dock.minY + 8, width: 50, height: 50)
            NSGradient(colors: [gradients[index].0, gradients[index].1])?
                .draw(in: NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12), angle: -70)
            let configuration = NSImage.SymbolConfiguration(pointSize: 23, weight: .medium)
            if let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
                    image.draw(in: drawRect.insetBy(dx: 12, dy: 12))
                    NSColor.white.set()
                    drawRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect.insetBy(dx: 12, dy: 12))
            }
        }
    }

    private static func drawTrafficLights(origin: CGPoint) {
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for index in 0..<3 {
            colors[index].setFill()
            NSBezierPath(ovalIn: CGRect(x: origin.x + CGFloat(index) * 17, y: origin.y, width: 10, height: 10)).fill()
        }
    }

    private static func drawFakeLines(in rect: CGRect, color: NSColor, lineHeight: CGFloat, gap: CGFloat, widths: [CGFloat]) {
        for (index, ratio) in widths.enumerated() {
            color.setFill()
            CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * (lineHeight + gap), width: rect.width * ratio, height: lineHeight).fill()
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func dropShadow(rect: CGRect, radius: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: radius, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        context.restoreGState()
    }

    private static func resetShadow() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
