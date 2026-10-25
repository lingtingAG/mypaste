import AppKit
import MyPasteCore

public enum EditorToolbarAction {
    case selectTool(Tool)
    case selectColor(RGBAColor)
    case selectLineWidth(CGFloat)
    case selectFontSize(CGFloat)
    case toggleFill
    case undo
    case redo
    case copy
    case save
    case pin
    case close
}

public protocol EditorToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: EditorToolbarView, perform action: EditorToolbarAction)
}

private final class ToolbarButton: NSButton {
    var isSelectedState = false {
        didSet { updateBackground() }
    }
    var isAccent = false {
        didSet { updateBackground() }
    }

    private var isHovering = false {
        didSet { updateBackground() }
    }
    private var trackingAreaRef: NSTrackingArea?

    init(symbolNames: [String], tooltip: String, accessibilityLabel: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 27, height: 26))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        self.toolTip = tooltip
        setAccessibilityLabel(accessibilityLabel)
        contentTintColor = .white
        let image = Self.symbol(names: symbolNames, pointSize: 13, weight: .medium)
        self.image = image
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 27).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbols(_ names: [String], selected: Bool) {
        image = Self.symbol(names: names, pointSize: 13, weight: selected ? .semibold : .medium)
    }

    static func symbol(names: [String], pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return image.withSymbolConfiguration(configuration)
            }
        }
        return NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func updateBackground() {
        guard let layer else { return }
        if isAccent {
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isHovering ? 0.95 : 0.82).cgColor
        } else if isSelectedState {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        } else if isHovering {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private final class ColorSwatchButton: NSButton {
    let swatch: RGBAColor
    var isSelectedState = false {
        didSet { needsDisplay = true }
    }
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingAreaRef: NSTrackingArea?

    init(color: RGBAColor) {
        self.swatch = color
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 22))
        isBordered = false
        title = ""
        refusesFirstResponder = true
        toolTip = "颜色 \(color.hexString)"
        setAccessibilityLabel("颜色 \(color.hexString)")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 21).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 13
        let circle = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        swatch.nsColor.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(ovalIn: circle.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        if isSelectedState {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 1.5
            ring.stroke()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

private final class WidthDotButton: NSButton {
    let lineWidth: CGFloat
    var isSelectedState = false {
        didSet { needsDisplay = true }
    }
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingAreaRef: NSTrackingArea?

    init(width: CGFloat) {
        self.lineWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 22))
        isBordered = false
        title = ""
        refusesFirstResponder = true
        toolTip = "线条粗细 \(Int(width)) pt"
        setAccessibilityLabel("线条粗细 \(Int(width))")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 21).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedState || isHovering {
            NSColor.white.withAlphaComponent(isSelectedState ? 0.2 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
        }
        let height = min(8, max(2, lineWidth))
        let dot = NSRect(
            x: (bounds.width - 12) / 2,
            y: (bounds.height - height) / 2,
            width: 12,
            height: height
        )
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: dot, xRadius: height / 2, yRadius: height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

private final class FontSizeButton: NSButton {
    private(set) var fontSize: CGFloat
    var onSelect: ((CGFloat) -> Void)?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingAreaRef: NSTrackingArea?

    private static let sizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 36, 40, 48, 56, 64, 80]

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init(frame: NSRect(x: 0, y: 0, width: 68, height: 22))
        isBordered = false
        title = ""
        refusesFirstResponder = true
        toolTip = "文字大小"
        setAccessibilityLabel("字号 \(Int(fontSize))")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 68).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateFontSize(_ size: CGFloat) {
        guard abs(size - fontSize) > 0.01 else { return }
        fontSize = size
        setAccessibilityLabel("字号 \(Int(size))")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let title = "字号 \(Int(fontSize))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: CGPoint(x: 7, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )

        NSColor.white.withAlphaComponent(0.42).setStroke()
        let chevronX = bounds.width - 11
        let centerY = bounds.midY
        let up = NSBezierPath()
        up.move(to: CGPoint(x: chevronX, y: centerY - 1))
        up.line(to: CGPoint(x: chevronX + 3.5, y: centerY - 4))
        up.line(to: CGPoint(x: chevronX + 7, y: centerY - 1))
        up.lineWidth = 1.1
        up.stroke()
        let down = NSBezierPath()
        down.move(to: CGPoint(x: chevronX, y: centerY + 2))
        down.line(to: CGPoint(x: chevronX + 3.5, y: centerY + 5))
        down.line(to: CGPoint(x: chevronX + 7, y: centerY + 2))
        down.lineWidth = 1.1
        down.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        var sizes = Self.sizes
        if !sizes.contains(where: { abs($0 - fontSize) < 0.1 }) {
            sizes.append(fontSize)
            sizes.sort()
        }
        for size in sizes {
            let item = NSMenuItem(
                title: "\(Int(size)) pt",
                action: #selector(chooseSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = size
            item.state = abs(size - fontSize) < 0.1 ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let size = CGFloat(number.doubleValue)
        updateFontSize(size)
        onSelect?(size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

private final class ToolbarSeparator: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 18))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

public final class EditorToolbarView: NSView {
    public weak var delegate: EditorToolbarDelegate?

    private let toolButtons: [Tool: ToolbarButton]
    private let colorButtons: [ColorSwatchButton]
    private let widthButtons: [WidthDotButton]
    private let undoButton: ToolbarButton
    private let redoButton: ToolbarButton
    private let fillButton: ToolbarButton
    private let fontSizeButton: FontSizeButton
    private let hintLabel: NSTextField
    private let drawOptionsStack = NSStackView()
    private let textOptionsStack = NSStackView()

    private static let tools: [Tool] = [
        .move, .rectangle, .ellipse, .arrow, .pen, .marker, .text, .mosaic, .blur, .number, .eraser,
    ]
    private static let widths: [CGFloat] = [2, 3, 4, 6, 8, 12]

    public override var isFlipped: Bool { true }

    public init() {
        var builtToolButtons: [Tool: ToolbarButton] = [:]
        for tool in Self.tools {
            builtToolButtons[tool] = ToolbarButton(
                symbolNames: Self.symbolNames(for: tool),
                tooltip: "\(tool.title)\(Self.toolShortcutHint(for: tool))",
                accessibilityLabel: tool.title
            )
        }
        toolButtons = builtToolButtons
        colorButtons = RGBAColor.palette.map { ColorSwatchButton(color: $0) }
        widthButtons = Self.widths.map { WidthDotButton(width: $0) }
        undoButton = ToolbarButton(
            symbolNames: ["arrow.uturn.backward"],
            tooltip: "撤销 (⌘Z)",
            accessibilityLabel: "撤销"
        )
        redoButton = ToolbarButton(
            symbolNames: ["arrow.uturn.forward"],
            tooltip: "重做 (⇧⌘Z)",
            accessibilityLabel: "重做"
        )
        fillButton = ToolbarButton(
            symbolNames: ["square.fill"],
            tooltip: "填充形状",
            accessibilityLabel: "填充形状"
        )
        fontSizeButton = FontSizeButton(fontSize: AppSettings.shared.toolFontSize)
        hintLabel = NSTextField(labelWithString: "Enter 复制   ·   P 贴图   ·   S 保存   ·   C 取色   ·   Esc 取消")
        super.init(frame: NSRect(x: 0, y: 0, width: 544, height: 92))

        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = true
        setupLayout()
        update(
            tool: .move,
            color: AppSettings.shared.toolColor,
            lineWidth: AppSettings.shared.toolLineWidth,
            filled: AppSettings.shared.toolFilled,
            fontSize: AppSettings.shared.toolFontSize,
            showsTextOptions: false,
            isTextEditing: false,
            canUndo: false,
            canRedo: false
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: 544, height: 92)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let panelRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: panelRect, xRadius: 10, yRadius: 10)
        NSColor(calibratedRed: 0.075, green: 0.08, blue: 0.09, alpha: 0.95).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    public func update(
        tool: Tool,
        color: RGBAColor,
        lineWidth: CGFloat,
        filled: Bool,
        fontSize: CGFloat,
        showsTextOptions: Bool,
        isTextEditing: Bool,
        canUndo: Bool,
        canRedo: Bool
    ) {
        for (buttonTool, button) in toolButtons {
            button.isSelectedState = buttonTool == tool
        }
        for button in colorButtons {
            button.isSelectedState = button.swatch == color
        }
        let closestWidth = Self.widths.min(by: { abs($0 - lineWidth) < abs($1 - lineWidth) }) ?? lineWidth
        for button in widthButtons {
            button.isSelectedState = button.lineWidth == closestWidth
        }
        fillButton.isSelectedState = filled
        fillButton.setSymbols([filled ? "square.fill" : "square"], selected: filled)
        fontSizeButton.updateFontSize(fontSize)
        let textContext = tool == .text || showsTextOptions
        drawOptionsStack.isHidden = textContext
        textOptionsStack.isHidden = !textContext
        if isTextEditing {
            hintLabel.stringValue = "输入文字   ·   拖动顶部手柄移动   ·   Enter 确认   ·   Esc 取消"
        } else if tool == .text {
            hintLabel.stringValue = "点击放置文字   ·   选择字号   ·   Enter 确认   ·   Esc 取消"
        } else if textContext {
            hintLabel.stringValue = "拖动文字移动   ·   双击重新编辑   ·   字号可调   ·   Delete 删除"
        } else {
            hintLabel.stringValue = "Enter 复制   ·   P 贴图   ·   S 保存   ·   C 取色   ·   Esc 取消"
        }
        undoButton.isEnabled = canUndo
        undoButton.alphaValue = canUndo ? 1 : 0.35
        redoButton.isEnabled = canRedo
        redoButton.alphaValue = canRedo ? 1 : 0.35
    }

    private func setupLayout() {
        let row1 = NSStackView()
        row1.orientation = .horizontal
        row1.alignment = .centerY
        row1.spacing = 2
        row1.translatesAutoresizingMaskIntoConstraints = false

        for tool in Self.tools {
            guard let button = toolButtons[tool] else { continue }
            button.target = self
            button.action = #selector(toolClicked(_:))
            button.tag = 100 + (Self.tools.firstIndex(of: tool) ?? 0)
            row1.addArrangedSubview(button)
        }
        row1.setCustomSpacing(8, after: toolButtons[.eraser]!)
        row1.addArrangedSubview(separator())
        row1.addArrangedSubview(undoButton)
        row1.addArrangedSubview(redoButton)
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        redoButton.target = self
        redoButton.action = #selector(redoClicked)
        row1.setCustomSpacing(8, after: redoButton)
        row1.addArrangedSubview(separator())

        let copyButton = ToolbarButton(symbolNames: ["doc.on.doc"], tooltip: "复制 (Enter)", accessibilityLabel: "复制")
        let saveButton = ToolbarButton(symbolNames: ["square.and.arrow.down"], tooltip: "保存 (S)", accessibilityLabel: "保存")
        let pinButton = ToolbarButton(symbolNames: ["pin"], tooltip: "贴图 (P)", accessibilityLabel: "贴图")
        let closeButton = ToolbarButton(symbolNames: ["xmark"], tooltip: "取消 (Esc)", accessibilityLabel: "取消")
        copyButton.isAccent = true
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        row1.addArrangedSubview(copyButton)
        row1.addArrangedSubview(saveButton)
        row1.addArrangedSubview(pinButton)
        row1.setCustomSpacing(6, after: pinButton)
        row1.addArrangedSubview(closeButton)

        let row2 = NSStackView()
        row2.orientation = .horizontal
        row2.alignment = .centerY
        row2.spacing = 1
        row2.translatesAutoresizingMaskIntoConstraints = false
        for (index, button) in colorButtons.enumerated() {
            button.target = self
            button.action = #selector(colorClicked(_:))
            button.tag = 300 + index
            row2.addArrangedSubview(button)
        }
        row2.setCustomSpacing(8, after: colorButtons.last!)

        drawOptionsStack.orientation = .horizontal
        drawOptionsStack.alignment = .centerY
        drawOptionsStack.spacing = 1
        drawOptionsStack.translatesAutoresizingMaskIntoConstraints = false
        drawOptionsStack.addArrangedSubview(separator())
        for (index, button) in widthButtons.enumerated() {
            button.target = self
            button.action = #selector(widthClicked(_:))
            button.tag = 400 + index
            drawOptionsStack.addArrangedSubview(button)
        }
        drawOptionsStack.setCustomSpacing(6, after: widthButtons.last!)
        fillButton.target = self
        fillButton.action = #selector(fillClicked)
        drawOptionsStack.addArrangedSubview(fillButton)
        row2.addArrangedSubview(drawOptionsStack)

        textOptionsStack.orientation = .horizontal
        textOptionsStack.alignment = .centerY
        textOptionsStack.spacing = 1
        textOptionsStack.translatesAutoresizingMaskIntoConstraints = false
        textOptionsStack.addArrangedSubview(separator())
        fontSizeButton.onSelect = { [weak self] size in
            guard let self else { return }
            self.delegate?.toolbar(self, perform: .selectFontSize(size))
        }
        textOptionsStack.addArrangedSubview(fontSizeButton)
        row2.addArrangedSubview(textOptionsStack)
        textOptionsStack.isHidden = true

        hintLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [row1, row2, hintLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 7, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func separator() -> ToolbarSeparator {
        ToolbarSeparator()
    }

    private static func symbolNames(for tool: Tool) -> [String] {
        switch tool {
        case .move: return ["cursorarrow", "arrow.up.and.down.and.arrow.left.and.right"]
        case .rectangle: return ["rectangle"]
        case .ellipse: return ["circle"]
        case .arrow: return ["arrow.up.right"]
        case .pen: return ["pencil.tip"]
        case .marker: return ["highlighter"]
        case .text: return ["textformat"]
        case .mosaic: return ["square.grid.3x3.fill", "square.grid.3x3"]
        case .blur: return ["camera.filters", "drop.halffull", "drop.fill"]
        case .number: return ["number.circle", "1.circle"]
        case .eraser: return ["eraser", "delete.left"]
        }
    }

    private static func toolShortcutHint(for tool: Tool) -> String {
        switch tool {
        case .move: return " (V)"
        case .rectangle: return " (R)"
        case .ellipse: return " (E)"
        case .arrow: return " (A)"
        case .pen: return " (B)"
        case .marker: return " (H)"
        case .text: return " (T)"
        case .mosaic: return " (M)"
        case .blur: return " (U)"
        case .number: return " (N)"
        case .eraser: return " (X)"
        }
    }

    @objc private func toolClicked(_ sender: NSButton) {
        let index = sender.tag - 100
        guard index >= 0, index < Self.tools.count else { return }
        delegate?.toolbar(self, perform: .selectTool(Self.tools[index]))
    }

    @objc private func colorClicked(_ sender: NSButton) {
        let index = sender.tag - 300
        guard index >= 0, index < RGBAColor.palette.count else { return }
        delegate?.toolbar(self, perform: .selectColor(RGBAColor.palette[index]))
    }

    @objc private func widthClicked(_ sender: NSButton) {
        let index = sender.tag - 400
        guard index >= 0, index < Self.widths.count else { return }
        delegate?.toolbar(self, perform: .selectLineWidth(Self.widths[index]))
    }

    @objc private func fillClicked() {
        delegate?.toolbar(self, perform: .toggleFill)
    }

    @objc private func undoClicked() {
        delegate?.toolbar(self, perform: .undo)
    }

    @objc private func redoClicked() {
        delegate?.toolbar(self, perform: .redo)
    }

    @objc private func copyClicked() {
        delegate?.toolbar(self, perform: .copy)
    }

    @objc private func saveClicked() {
        delegate?.toolbar(self, perform: .save)
    }

    @objc private func pinClicked() {
        delegate?.toolbar(self, perform: .pin)
    }

    @objc private func closeClicked() {
        delegate?.toolbar(self, perform: .close)
    }
}
