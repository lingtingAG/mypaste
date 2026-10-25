import AppKit
import MyPasteCore

final class TextEditingBox: NSView, NSTextFieldDelegate {
    static let headerHeight: CGFloat = 20
    static let minimumFieldWidth: CGFloat = 140

    let textField: NSTextField
    private(set) var fontSize: CGFloat
    private(set) var color: RGBAColor
    private var maxTextWidth: CGFloat
    private var dragAnchor: (mouse: CGPoint, origin: CGPoint)?

    var constrainOrigin: ((CGPoint, CGSize) -> CGPoint)?
    var onOriginChanged: (() -> Void)?
    var onTextChanged: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    var bodyOrigin: CGPoint {
        CGPoint(x: frame.minX, y: frame.minY + Self.headerHeight)
    }

    init(
        origin: CGPoint,
        width: CGFloat,
        maxWidth: CGFloat,
        fontSize: CGFloat,
        color: RGBAColor,
        text: String
    ) {
        self.fontSize = min(120, max(10, fontSize))
        self.color = color
        let initialFieldWidth = max(60, width - TextMetrics.padding.width * 2)
        self.maxTextWidth = max(initialFieldWidth, maxWidth - TextMetrics.padding.width * 2)
        let bodyHeight = Self.bodyHeight(for: self.fontSize)
        self.textField = NSTextField(frame: .zero)
        super.init(frame: CGRect(
            x: origin.x,
            y: origin.y,
            width: initialFieldWidth + TextMetrics.padding.width * 2,
            height: Self.headerHeight + bodyHeight
        ))
        textField.font = TextMetrics.font(size: self.fontSize)
        textField.textColor = color.nsColor
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.appearance = NSAppearance(named: .aqua)
        textField.delegate = self
        textField.setAccessibilityLabel("文字输入")
        textField.stringValue = text
        addSubview(textField)
        updatePlaceholder()
        layoutContents()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func focusField() {
        window?.makeFirstResponder(textField)
        if let editor = textField.currentEditor() as? NSTextView {
            editor.insertionPointColor = NSColor.controlAccentColor
        }
    }

    func setText(_ text: String, selectAll: Bool = false) {
        textField.stringValue = text
        resizeToFitText()
        needsDisplay = true
        if selectAll {
            textField.currentEditor()?.selectAll(nil)
        }
    }

    func updateFontSize(_ size: CGFloat) {
        fontSize = min(120, max(10, size))
        textField.font = TextMetrics.font(size: fontSize)
        updatePlaceholder()
        let bodyHeight = Self.bodyHeight(for: fontSize)
        frame.size.height = Self.headerHeight + bodyHeight
        resizeToFitText()
        layoutContents()
        needsDisplay = true
    }

    func updateColor(_ newColor: RGBAColor) {
        color = newColor
        textField.textColor = newColor.nsColor
        needsDisplay = true
    }

    func setAvailableWidth(_ available: CGFloat) {
        let limit = max(60, available - TextMetrics.padding.width * 2)
        maxTextWidth = limit
        if fieldWidth > limit {
            setFieldWidth(limit)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if local.y <= Self.headerHeight { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y <= Self.headerHeight else {
            focusField()
            return
        }
        dragAnchor = (point, frame.origin)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let proposed = CGPoint(
            x: dragAnchor.origin.x + point.x - dragAnchor.mouse.x,
            y: dragAnchor.origin.y + point.y - dragAnchor.mouse.y
        )
        frame.origin = constrainOrigin?(proposed, bounds.size) ?? proposed
        onOriginChanged?()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragAnchor != nil
        dragAnchor = nil
        if wasDragging {
            focusField()
            window?.invalidateCursorRects(for: self)
            NSCursor.openHand.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(
            CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight),
            cursor: .openHand
        )
        let body = CGRect(
            x: 0,
            y: Self.headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.headerHeight)
        )
        addCursorRect(body, cursor: .iBeam)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let headerRect = CGRect(
            x: outer.minX,
            y: outer.minY,
            width: outer.width,
            height: Self.headerHeight
        )
        let headerPath = NSBezierPath(roundedRect: headerRect, xRadius: 5, yRadius: 5)
        NSColor(calibratedWhite: 0.075, alpha: 0.86).setFill()
        headerPath.fill()

        let bodyRect = CGRect(
            x: outer.minX,
            y: Self.headerHeight + 0.5,
            width: outer.width,
            height: max(0, outer.height - Self.headerHeight - 1)
        )
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 4, yRadius: 4)
        bodyPath.setLineDash([4, 3], count: 2, phase: 0)
        bodyPath.lineWidth = 1.2
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        bodyPath.stroke()

        drawHeader()
    }

    private func drawHeader() {
        let gripColor = NSColor.white.withAlphaComponent(0.38)
        gripColor.setFill()
        for row in 0..<2 {
            for column in 0..<2 {
                let dot = CGRect(
                    x: 9 + CGFloat(column) * 4,
                    y: 8 + CGFloat(row) * 4,
                    width: 2,
                    height: 2
                )
                NSBezierPath(ovalIn: dot).fill()
            }
        }

        let dragAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        ("拖动" as NSString).draw(
            at: CGPoint(x: 21, y: 4),
            withAttributes: dragAttributes
        )

        let sizeText = "\(Int(fontSize)) pt"
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let sizeAttributes: [NSAttributedString.Key: Any] = [
            .font: sizeFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ]
        let sizeWidth = (sizeText as NSString).size(withAttributes: sizeAttributes).width
        (sizeText as NSString).draw(
            at: CGPoint(x: bounds.width - sizeWidth - 9, y: 4.5),
            withAttributes: sizeAttributes
        )
    }

    private func updatePlaceholder() {
        textField.placeholderAttributedString = NSAttributedString(
            string: "输入文字",
            attributes: [
                .font: TextMetrics.font(size: fontSize),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 0.95),
            ]
        )
    }

    private var bodyHeight: CGFloat {
        Self.bodyHeight(for: fontSize)
    }

    private static func bodyHeight(for fontSize: CGFloat) -> CGFloat {
        TextMetrics.textRect(origin: .zero, string: "Ag", fontSize: fontSize).height
    }

    private var fieldWidth: CGFloat {
        max(60, bounds.width - TextMetrics.padding.width * 2)
    }

    private func layoutContents() {
        let height = max(16, bodyHeight - TextMetrics.padding.height * 2 + 2)
        textField.frame = CGRect(
            x: TextMetrics.padding.width,
            y: Self.headerHeight + TextMetrics.padding.height - 1,
            width: fieldWidth,
            height: height
        )
        window?.invalidateCursorRects(for: self)
    }

    private func resizeToFitText() {
        let sample = textField.stringValue.isEmpty ? "输入文字" : textField.stringValue
        let measured = TextMetrics.textSize(sample, fontSize: fontSize)
        let desired = max(Self.minimumFieldWidth, measured.width + 18)
        let target = min(maxTextWidth, max(fieldWidth, desired))
        if abs(target - fieldWidth) > 0.5 {
            setFieldWidth(target)
        }
    }

    private func setFieldWidth(_ width: CGFloat) {
        frame.size.width = width + TextMetrics.padding.width * 2
        layoutContents()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        resizeToFitText()
        needsDisplay = true
        onTextChanged?()
    }
}
