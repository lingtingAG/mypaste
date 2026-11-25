import AppKit
import MyPasteCore

public enum CaptureInteractionMode {
    case edit
    case colorPicker
}

public struct SnapshotTextEditing {
    public let origin: CGPoint
    public let text: String
    public let fontSize: CGFloat

    public init(origin: CGPoint, text: String, fontSize: CGFloat) {
        self.origin = origin
        self.text = text
        self.fontSize = fontSize
    }
}

private enum CanvasDragState {
    case none
    case creating(start: CGPoint)
    case moving(start: CGPoint, initial: CGRect)
    case resizing(handle: ResizeHandle, initial: CGRect)
    case drawing(start: CGPoint)
    case movingText(id: UUID, start: CGPoint, initialOrigin: CGPoint)
}

private struct AnnotationCache {
    let image: CGImage
    let selection: CGRect
    let annotations: [Annotation]
    /// 位图内容对应的选区局部原点：整图位图为 .zero，瓦片为包围盒左上角
    let origin: CGPoint
}

public final class BaseImageView: NSView {
    public var image: CGImage? {
        didSet { needsDisplay = true }
    }

    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()
        bounds.fill()
        if let image {
            context.interpolationQuality = .high
            AnnotationRenderer.drawImageTopLeft(image, in: bounds, in: context)
        }
    }
}

public final class SelectionCanvasView: NSView, EditorToolbarDelegate {
    weak var session: CaptureSession?

    let captured: CapturedScreen
    let mode: CaptureInteractionMode
    private let windowDetector = WindowDetector()

    private(set) var selection: CGRect?
    private(set) var annotations: [Annotation] = [] {
        didSet {
            annotationCache = nil
            annotationCacheHead = nil
            annotationCacheTail = nil
        }
    }
    private var annotationCache: AnnotationCache?
    // 拖动中的文字把已提交标注切成前后两段分别缓存，保证层叠顺序与提交后一致。
    // 两段按各自标注的包围盒渲染成瓦片，常驻内存与标注范围成正比而非整张选区
    private var annotationCacheHead: AnnotationCache?
    private var annotationCacheTail: AnnotationCache?
    // 标注位图层实际重建次数（回归测试用）：拖动文字 / 移动选区不应逐帧重建整图
    private(set) var annotationLayerRenderCount = 0
    /// 拖动期常驻瓦片的像素总数（回归测试用）：
    /// 拖字时应与标注自身范围成正比，而不是整张选区的像素数
    var cachedTilePixelCount: Int {
        let head = annotationCacheHead.map { $0.image.width * $0.image.height } ?? 0
        let tail = annotationCacheTail.map { $0.image.width * $0.image.height } ?? 0
        return head + tail
    }
    // 拖动中的文字：拖动过程不改动 annotations，避免每个鼠标事件重建标注位图
    private var movingTextOverlay: Annotation?
    // 会话级效果缓存：生命周期与画布/源图一致，避免跨会话串用与跨线程共享
    private let effectCache = AnnotationEffectCache()
    lazy var pixelSampler = PixelSampler(image: captured.image)
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var currentAnnotation: Annotation?
    private let initialTool: Tool
    private(set) var tool: Tool = .move
    private(set) var currentColor = AppSettings.shared.toolColor
    private(set) var currentLineWidth = AppSettings.shared.toolLineWidth
    private(set) var currentFontSize = AppSettings.shared.toolFontSize
    private(set) var currentlyFilled = AppSettings.shared.toolFilled

    private var dragState: CanvasDragState = .none
    private var cursorPoint: CGPoint?
    private var hoveredWindow: DetectedWindow?
    private var pendingWindowSelection: DetectedWindow?
    private var toolbar: EditorToolbarView?
    private(set) var textEditingBox: TextEditingBox?
    private var editingTextID: UUID?
    private var textEditingUndoSnapshot: [Annotation]?
    private(set) var selectedTextID: UUID?
    private var movingTextSnapshot: [Annotation]?
    private var movingTextDidChange = false
    // 连续方向键微调合并为一次撤销记录，避免长按刷满撤销栈
    private var nudgingSelectedText = false
    private var toastText: String?
    private var toastWorkItem: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?
    private var didPickColor = false

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { false }

    public init(captured: CapturedScreen, mode: CaptureInteractionMode = .edit) {
        self.captured = captured
        self.mode = mode
        self.initialTool = AppSettings.shared.lastTool
        self.tool = self.initialTool
        super.init(frame: NSRect(origin: .zero, size: captured.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layout() {
        super.layout()
        layoutToolbar()
    }

    public override func updateTrackingAreas() {
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

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Pointer

    func updatePointerFromSystem() {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else { return }
        cursorPoint = local
        refreshHoveredWindow(at: local)
        updateCursor(at: local)
        needsDisplay = true
    }

    private func refreshHoveredWindow(at point: CGPoint) {
        guard mode == .edit, selection == nil, case .none = dragState else { return }
        let detected = windowDetector.window(at: point, on: captured.screen)
        if detected?.windowID != hoveredWindow?.windowID || detected?.localRect != hoveredWindow?.localRect {
            hoveredWindow = detected
            needsDisplay = true
        }
    }

    private func pointerLocation() -> CGPoint? {
        if let cursorPoint { return cursorPoint }
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(windowPoint, from: nil)
        return bounds.contains(local) ? local : nil
    }

    // MARK: - Mouse

    public override func mouseEntered(with event: NSEvent) {
        session?.activate(canvas: self)
        cursorPoint = convert(event.locationInWindow, from: nil)
        updateCursor(at: cursorPoint)
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    public override func mouseMoved(with event: NSEvent) {
        let previous = cursorPoint
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if mode == .colorPicker {
            needsDisplay = true
            return
        }
        if selection == nil {
            let previousHighlight = hoveredWindow?.localRect
            refreshHoveredWindow(at: point)
            // 窗口高亮整块变化时 refreshHoveredWindow 已请求整屏重绘；
            // 其余情况只标脏旧/新光标的十字线与放大镜区域
            if previousHighlight == hoveredWindow?.localRect {
                for rect in cursorDirtyRects(old: previous, new: point) {
                    setNeedsDisplay(rect)
                }
            }
        } else if case .drawing = dragState {
            needsDisplay = true
        }
        updateCursor(at: point)
    }

    public override func mouseDown(with event: NSEvent) {
        guard mode == .edit else {
            pickColor(at: convert(event.locationInWindow, from: nil))
            return
        }
        if textEditingBox != nil {
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        nudgingSelectedText = false
        guard let window else { return }
        session?.activate(canvas: self)
        window.acceptsMouseMovedEvents = true
        let point = clampPoint(convert(event.locationInWindow, from: nil))
        cursorPoint = point

        if selection == nil {
            pendingWindowSelection = hoveredWindow
            dragState = .creating(start: point)
            selection = CGRect(origin: point, size: .zero)
            hoveredWindow = nil
            needsDisplay = true
            return
        }

        guard let currentSelection = selection else { return }
        // 小选区不绘制手柄（见 drawSelectionChrome），也不应响应手柄热区，否则内部点击会变成缩放
        if currentSelection.width > 18, currentSelection.height > 18,
           let handle = Geometry.handleHit(at: point, in: currentSelection, tolerance: 8) {
            dragState = .resizing(handle: handle, initial: currentSelection)
            updateCursor(at: point)
            return
        }

        guard currentSelection.contains(point) else {
            resetSelection()
            pendingWindowSelection = nil
            dragState = .creating(start: point)
            selection = CGRect(origin: point, size: .zero)
            hoveredWindow = nil
            needsDisplay = true
            return
        }

        if tool == .move, let hit = textAnnotation(at: point) {
            currentColor = hit.color
            if case let .text(_, _, fontSize) = hit.kind {
                currentFontSize = fontSize
            }
            selectedTextID = hit.id
            updateToolbarState()
            if event.clickCount >= 2 {
                beginTextEditing(at: localPoint(point), existing: hit)
            } else {
                let origin: CGPoint
                if case let .text(textOrigin, _, _) = hit.kind {
                    origin = textOrigin
                } else {
                    origin = .zero
                }
                dragState = .movingText(id: hit.id, start: point, initialOrigin: origin)
                movingTextSnapshot = annotations
                movingTextOverlay = nil
                movingTextDidChange = false
                updateCursor(at: point)
            }
            needsDisplay = true
            return
        }

        if selectedTextID != nil {
            selectedTextID = nil
            updateToolbarState()
            needsDisplay = true
        }

        if event.clickCount >= 2, tool == .move {
            session?.canvasRequestCopy(self)
            return
        }

        let local = localPoint(point)
        switch tool {
        case .move:
            dragState = .moving(start: point, initial: currentSelection)
            updateCursor(at: point)
        case .text:
            beginTextEditing(at: local)
        case .number:
            addNumber(at: local)
        case .eraser:
            erase(at: local)
        case .rectangle, .ellipse, .arrow, .pen, .marker, .mosaic, .blur:
            dragState = .drawing(start: local)
            currentAnnotation = makeAnnotation(tool: tool, localStart: local, localEnd: local)
            needsDisplay = true
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard mode == .edit else {
            cursorPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        let point = clampPoint(convert(event.locationInWindow, from: nil))
        cursorPoint = point
        let shift = event.modifierFlags.contains(.shift)

        switch dragState {
        case let .creating(start):
            var end = point
            if shift {
                end = Geometry.constrainedEnd(from: start, to: end, square: true, angleSnap: false)
            }
            selection = Geometry.selectionRect(from: start, to: end, in: bounds)
            hoveredWindow = nil
            needsDisplay = true

        case let .moving(start, initial):
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            selection = Geometry.movedRect(initial, by: delta, in: bounds)
            layoutToolbar()
            needsDisplay = true

        case let .resizing(handle, initial):
            selection = Geometry.resizedRect(initial, handle: handle, to: point, in: bounds)
            layoutToolbar()
            needsDisplay = true

        case let .movingText(id, start, initialOrigin):
            guard let selection,
                  let index = annotations.firstIndex(where: { $0.id == id }),
                  case let .text(_, string, fontSize) = annotations[index].kind
            else { break }
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            let textSize = TextMetrics.textRect(origin: .zero, string: string, fontSize: fontSize).size
            var origin = CGPoint(x: initialOrigin.x + delta.x, y: initialOrigin.y + delta.y)
            origin.x = min(max(0, origin.x), max(0, selection.width - textSize.width))
            origin.y = min(max(0, origin.y), max(0, selection.height - textSize.height))
            // 拖动过程只更新覆盖层，不改动已提交集合：否则每个鼠标事件都会让标注位图整张重建
            var overlay = annotations[index]
            overlay.kind = .text(origin: origin, string: string, fontSize: fontSize)
            movingTextOverlay = overlay
            if hypot(delta.x, delta.y) > 0.5 {
                movingTextDidChange = true
            }
            needsDisplay = true

        case .drawing:
            updateCurrentAnnotation(to: point, shift: shift)

        case .none:
            break
        }
        updateCursor(at: point)
    }

    public override func mouseUp(with event: NSEvent) {
        guard mode == .edit else { return }
        let point = clampPoint(convert(event.locationInWindow, from: nil))
        cursorPoint = point

        switch dragState {
        case let .creating(start):
            var finalRect = selection ?? .zero
            let traveled = hypot(point.x - start.x, point.y - start.y)
            if traveled < 3 {
                if let pendingWindowSelection {
                    finalRect = pendingWindowSelection.localRect
                } else {
                    finalRect = bounds
                }
                finalRect = Geometry.clampedRect(finalRect, to: bounds)
                if finalRect.width < 8 || finalRect.height < 8 {
                    finalRect = bounds
                }
            } else {
                // 有意的细长拖选尊重用户尺寸，只钳位到最小可编辑尺寸，不替换为全屏
                finalRect = Geometry.clampedRect(finalRect, to: bounds)
                finalRect.size.width = max(finalRect.width, min(8, bounds.width))
                finalRect.size.height = max(finalRect.height, min(8, bounds.height))
                finalRect = Geometry.clampedRect(finalRect, to: bounds)
            }
            selection = finalRect
            annotations.removeAll()
            undoStack.removeAll()
            redoStack.removeAll()
            selectedTextID = nil
            tool = initialTool
            pendingWindowSelection = nil
            hoveredWindow = nil
            showToolbar()
            window?.makeFirstResponder(self)

        case .moving, .resizing:
            if let currentSelection = selection {
                selection = Geometry.clampedRect(currentSelection, to: bounds)
            }
            layoutToolbar()
            updateToolbarState()

        case .movingText:
            if movingTextDidChange, let snapshot = movingTextSnapshot {
                pushUndoSnapshot(snapshot)
                // 拖动结束才落到已提交集合：整场拖动只重建一次标注位图
                if let overlay = movingTextOverlay,
                   let index = annotations.firstIndex(where: { $0.id == overlay.id }) {
                    annotations[index].kind = overlay.kind
                }
            }
            movingTextSnapshot = nil
            movingTextOverlay = nil
            movingTextDidChange = false
            updateToolbarState()

        case .drawing:
            finishCurrentAnnotation()

        case .none:
            break
        }

        dragState = .none
        updateCursor(at: point)
        needsDisplay = true
    }

    public override func rightMouseDown(with event: NSEvent) {
        if textEditingBox != nil {
            cancelTextEditing()
            return
        }
        // 绘制中右键只取消当前笔画，不退出整个截图会话
        if case .drawing = dragState {
            dragState = .none
            currentAnnotation = nil
            needsDisplay = true
            return
        }
        session?.cancel()
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            session?.cancel()
            return
        }
        if mode == .colorPicker {
            if event.keyCode == 36 || event.keyCode == 76 {
                if let pointer = pointerLocation() { pickColor(at: pointer) }
            }
            return
        }

        // 统一走 ⌘ 组合键：工具栏每个按钮都有一个组合（与按钮提示一致）
        if event.modifierFlags.contains(.command) {
            if handleCommandShortcut(event) { return }
            super.keyDown(with: event)
            return
        }

        guard let selection else {
            super.keyDown(with: event)
            return
        }

        let pointStep: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
        if selectedTextID != nil {
            if event.keyCode == 51 {
                deleteSelectedText()
                return
            }
            if handleArrowKeyForSelectedText(event.keyCode, step: pointStep) {
                return
            }
        }
        if handleArrowKey(event.keyCode, selection: selection, step: pointStep, resize: event.modifierFlags.contains(.shift)) {
            return
        }

        if event.keyCode == 51 {
            undoLastAnnotation()
            return
        }
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                requestSelectWholeScreen()
            }
            return
        }
        super.keyDown(with: event)
    }

    enum EditorCommand: Hashable {
        case tool(Tool)
        case copy
        case save
        case pin
        case copyColor
        case toggleFill
        case fontSize
        case undo
        case redo
    }

    /// 编辑器命令表：组合键 → 动作。**唯一数据源**，
    /// 快捷键响应、工具栏按钮提示、设置里的使用说明、回归测试都读它。
    ///
    /// 组合必须避开主菜单已占用的键：编辑菜单的 ⌘X/⌘C/⌘V/⌘A、应用菜单的 ⌘H/⌘Q/⌘,。
    /// 主菜单的快捷键在事件进入第一响应者**之前**就被消费，撞车时画布根本收不到按键。
    ///
    /// 实测（AppKit 菜单匹配规则）：菜单项的修饰键掩码只要是事件修饰键的**子集**就算命中，
    /// **额外的 Shift 不算避让**——所以 ⌘V 的变体 ⇧⌘V 同样会被「粘贴」吃掉。
    /// 编辑菜单又不能删：没有它，文字输入框的 ⌘C/⌘V 会失效（实测只有 ⌘A 仍可用）。
    /// 因此编辑器只能用空闲字母：移动 ⌘G / 箭头 ⌘J / 橡皮擦 ⌘K / 取色 ⌘L。
    /// 复制 ⌘C、撤销 ⌘Z、重做 ⇧⌘Z 与菜单共享是安全的——菜单动作与画布动作完全一致。
    static let commandShortcuts: [(command: EditorCommand, key: String, modifiers: NSEvent.ModifierFlags)] = [
        (.tool(.move), "g", [.command]),
        (.tool(.rectangle), "r", [.command]),
        (.tool(.ellipse), "e", [.command]),
        (.tool(.arrow), "j", [.command]),
        (.tool(.pen), "b", [.command]),
        (.tool(.marker), "i", [.command]),
        (.tool(.text), "t", [.command]),
        (.tool(.mosaic), "d", [.command]),
        (.tool(.blur), "u", [.command]),
        (.tool(.number), "n", [.command]),
        (.tool(.eraser), "k", [.command]),
        (.copy, "c", [.command]),
        (.save, "s", [.command]),
        (.pin, "p", [.command]),
        (.copyColor, "l", [.command]),
        (.toggleFill, "f", [.command]),
        (.fontSize, "f", [.command, .shift]),
        // 撤销 / 重做与编辑菜单共享同一组合与同一动作，列入表里才能在设置说明中一并列出
        (.undo, "z", [.command]),
        (.redo, "z", [.command, .shift]),
    ]

    /// 组合键的可读形式，如 ⇧⌘V
    static func shortcutLabel(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + key.uppercased()
    }

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let entry = Self.commandShortcuts.first(where: { $0.key == key && $0.modifiers == modifiers }) else {
            return false
        }
        switch entry.command {
        case let .tool(tool):
            selectTool(tool)
        case .copy:
            if selection != nil { session?.canvasRequestCopy(self) }
        case .save:
            if selection != nil { session?.canvasRequestSave(self) }
        case .pin:
            session?.canvasRequestPin(self)
        case .copyColor:
            copyColorUnderCursor()
        case .toggleFill:
            toggleFillShape()
        case .fontSize:
            toolbar?.presentFontSizeMenu()
        case .undo:
            undoLastAnnotation()
        case .redo:
            redoLastAnnotation()
        }
        return true
    }

    /// ⌘F：切换形状填充（与工具栏「填充形状」按钮一致）
    private func toggleFillShape() {
        currentlyFilled.toggle()
        AppSettings.shared.toolFilled = currentlyFilled
        updateToolbarState()
        needsDisplay = true
    }

    private func handleArrowKey(_ keyCode: UInt16, selection: CGRect, step: CGFloat, resize: Bool) -> Bool {
        var rect = selection
        switch keyCode {
        case 123:
            if resize { rect.size.width = max(8, rect.width - step) } else { rect.origin.x -= step }
        case 124:
            if resize { rect.size.width += step } else { rect.origin.x += step }
        case 125:
            if resize { rect.size.height += step } else { rect.origin.y += step }
        case 126:
            if resize { rect.size.height = max(8, rect.height - step) } else { rect.origin.y -= step }
        default:
            return false
        }
        if resize {
            self.selection = Geometry.clampedRect(rect, to: bounds)
        } else {
            self.selection = Geometry.movedRect(rect, by: .zero, in: bounds)
        }
        layoutToolbar()
        needsDisplay = true
        return true
    }

    private func handleArrowKeyForSelectedText(_ keyCode: UInt16, step: CGFloat) -> Bool {
        guard let selectedTextID,
              let index = annotations.firstIndex(where: { $0.id == selectedTextID }),
              case let .text(origin, string, fontSize) = annotations[index].kind
        else { return false }
        var next = origin
        switch keyCode {
        case 123: next.x -= step
        case 124: next.x += step
        case 125: next.y += step
        case 126: next.y -= step
        default: return false
        }
        if let selection {
            let size = TextMetrics.textRect(origin: .zero, string: string, fontSize: fontSize).size
            next.x = min(max(0, next.x), max(0, selection.width - size.width))
            next.y = min(max(0, next.y), max(0, selection.height - size.height))
        }
        guard next != origin else { return true }
        if !nudgingSelectedText {
            pushUndoSnapshot()
            nudgingSelectedText = true
        }
        annotations[index].kind = .text(origin: next, string: string, fontSize: fontSize)
        needsDisplay = true
        return true
    }

    private func deleteSelectedText() {
        guard let selectedTextID,
              let index = annotations.firstIndex(where: { $0.id == selectedTextID })
        else { return }
        pushUndoSnapshot()
        annotations.remove(at: index)
        self.selectedTextID = nil
        updateToolbarState()
        needsDisplay = true
    }

    @objc public func copy(_ sender: Any?) {
        guard selection != nil else { return }
        session?.canvasRequestCopy(self)
    }

    @objc public func undo(_ sender: Any?) {
        undoLastAnnotation()
    }

    @objc public func redo(_ sender: Any?) {
        redoLastAnnotation()
    }

    public override func selectAll(_ sender: Any?) {
        requestSelectWholeScreen()
    }

    /// 选满整屏：只在还没有选区时可用。
    /// 编辑中改选区会连带丢掉标注与撤销栈，而 ⌘A 是肌肉记忆键，
    /// 不能变成「误触即丢数据」的陷阱（编辑中请按 Esc 重新截图）。
    private func requestSelectWholeScreen() {
        guard selection == nil else {
            showToast("编辑中不能改选区，请按 Esc 重新截图")
            return
        }
        selection = bounds
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedTextID = nil
        tool = initialTool
        showToolbar()
        needsDisplay = true
    }

    // MARK: - Tools

    private func selectTool(_ newTool: Tool) {
        guard selection != nil else { return }
        commitTextEditing()
        selectedTextID = nil
        tool = newTool
        AppSettings.shared.lastTool = newTool
        window?.makeFirstResponder(self)
        updateToolbarState()
        updateCursor(at: pointerLocation())
        needsDisplay = true
    }

    private func makeAnnotation(tool: Tool, localStart: CGPoint, localEnd: CGPoint) -> Annotation? {
        let kind: AnnotationKind
        switch tool {
        case .rectangle:
            kind = .rectangle(Geometry.normalizedRect(from: localStart, to: localEnd))
        case .ellipse:
            kind = .ellipse(Geometry.normalizedRect(from: localStart, to: localEnd))
        case .arrow:
            kind = .arrow(from: localStart, to: localEnd)
        case .pen:
            kind = .pen(points: [localStart])
        case .marker:
            kind = .marker(points: [localStart])
        case .mosaic:
            kind = .mosaic(Geometry.normalizedRect(from: localStart, to: localEnd))
        case .blur:
            kind = .blur(Geometry.normalizedRect(from: localStart, to: localEnd))
        case .text, .number, .eraser, .move:
            return nil
        }
        return Annotation(
            kind: kind,
            color: currentColor,
            lineWidth: currentLineWidth,
            filled: currentlyFilled
        )
    }

    private func updateCurrentAnnotation(to point: CGPoint, shift: Bool) {
        guard let selection, case let .drawing(start) = dragState, var annotation = currentAnnotation else { return }
        let localStart = clampLocalPoint(start, in: selection)
        var localEnd = clampLocalPoint(localPoint(point), in: selection)

        switch tool {
        case .rectangle, .ellipse, .mosaic, .blur:
            if shift {
                localEnd = Geometry.constrainedEnd(from: localStart, to: localEnd, square: true, angleSnap: false)
            }
            let rect = Geometry.normalizedRect(from: localStart, to: localEnd)
            switch tool {
            case .rectangle: annotation.kind = .rectangle(rect)
            case .ellipse: annotation.kind = .ellipse(rect)
            case .mosaic: annotation.kind = .mosaic(rect)
            case .blur: annotation.kind = .blur(rect)
            default: break
            }
        case .arrow:
            let end = shift
                ? Geometry.constrainedEnd(from: localStart, to: localEnd, square: false, angleSnap: true)
                : localEnd
            annotation.kind = .arrow(from: localStart, to: end)
        case .pen, .marker:
            var points: [CGPoint]
            if case let .pen(existing) = annotation.kind {
                points = existing
            } else if case let .marker(existing) = annotation.kind {
                points = existing
            } else {
                points = [localStart]
            }
            if let last = points.last {
                let distance = hypot(localEnd.x - last.x, localEnd.y - last.y)
                if distance >= 1.2 {
                    points.append(localEnd)
                }
            } else {
                points.append(localEnd)
            }
            annotation.kind = tool == .pen ? .pen(points: points) : .marker(points: points)
        default:
            break
        }
        currentAnnotation = annotation
        needsDisplay = true
    }

    private func finishCurrentAnnotation() {
        guard let annotation = currentAnnotation else { return }
        currentAnnotation = nil
        guard isAnnotationValid(annotation) else {
            needsDisplay = true
            return
        }
        pushUndoSnapshot()
        annotations.append(annotation)
        updateToolbarState()
        needsDisplay = true
    }

    private func isAnnotationValid(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect), let .blur(rect):
            return rect.width >= 3 && rect.height >= 3
        case let .arrow(from, to):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case let .pen(points), let .marker(points):
            return !points.isEmpty
        case let .text(_, string, _):
            return !string.isEmpty
        case .number:
            return true
        }
    }

    private func addNumber(at localPoint: CGPoint) {
        let next = (annotations.compactMap { annotation -> Int? in
            if case let .number(_, value) = annotation.kind { return value }
            return nil
        }.max() ?? 0) + 1
        pushUndoSnapshot()
        annotations.append(Annotation(
            kind: .number(center: localPoint, value: next),
            color: currentColor,
            lineWidth: currentLineWidth,
            filled: currentlyFilled
        ))
        updateToolbarState()
        needsDisplay = true
    }

    private func erase(at localPoint: CGPoint) {
        guard let index = annotations.lastIndex(where: { $0.hitTest(localPoint) }) else { return }
        pushUndoSnapshot()
        if annotations[index].id == selectedTextID {
            selectedTextID = nil
        }
        annotations.remove(at: index)
        updateToolbarState()
        needsDisplay = true
    }

    private func undoLastAnnotation() {
        guard let previous = undoStack.popLast() else { return }
        nudgingSelectedText = false
        redoStack.append(annotations)
        annotations = previous
        clearMissingTextSelection()
        updateToolbarState()
        needsDisplay = true
    }

    private func redoLastAnnotation() {
        guard let next = redoStack.popLast() else { return }
        nudgingSelectedText = false
        undoStack.append(annotations)
        annotations = next
        clearMissingTextSelection()
        updateToolbarState()
        needsDisplay = true
    }

    private func clearMissingTextSelection() {
        guard let selectedTextID else { return }
        if !annotations.contains(where: { $0.id == selectedTextID }) {
            self.selectedTextID = nil
        }
    }

    private func pushUndoSnapshot() {
        pushUndoSnapshot(annotations)
    }

    private func pushUndoSnapshot(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        nudgingSelectedText = false
        updateToolbarState()
    }

    // MARK: - Text editing

    private var selectedTextAnnotation: Annotation? {
        guard let selectedTextID else { return nil }
        return annotations.first { $0.id == selectedTextID }
    }

    private var displayedTextFontSize: CGFloat {
        if let textEditingBox { return textEditingBox.fontSize }
        if let selectedTextAnnotation, case let .text(_, _, fontSize) = selectedTextAnnotation.kind {
            return fontSize
        }
        return currentFontSize
    }

    private var isTextContext: Bool {
        tool == .text || textEditingBox != nil || selectedTextAnnotation != nil
    }

    private func textAnnotation(at point: CGPoint) -> Annotation? {
        guard let selection else { return nil }
        let local = CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
        return annotations.reversed().first { annotation in
            guard case .text(_, _, _) = annotation.kind else { return false }
            return annotation.hitTest(local, tolerance: 4)
        }
    }

    private func beginTextEditing(
        at localPoint: CGPoint,
        existing: Annotation? = nil,
        presetText: String? = nil,
        presetFontSize: CGFloat? = nil
    ) {
        guard let selection, textEditingBox == nil else { return }

        var editingString = presetText ?? ""
        var bodyPoint = CGPoint(x: selection.minX + localPoint.x, y: selection.minY + localPoint.y)
        var fontSize = presetFontSize ?? currentFontSize
        var color = currentColor

        if let existing, case let .text(origin, string, existingSize) = existing.kind {
            editingString = string
            bodyPoint = CGPoint(x: selection.minX + origin.x, y: selection.minY + origin.y)
            fontSize = existingSize
            color = existing.color
            currentFontSize = existingSize
            currentColor = existing.color
            editingTextID = existing.id
            selectedTextID = existing.id
            textEditingUndoSnapshot = annotations
        }

        let measuredWidth = TextMetrics.textSize(editingString, fontSize: fontSize).width
        let preferredWidth = max(252, measuredWidth + 54)
        let availableWidth = max(80, min(bounds.maxX, selection.maxX) - bodyPoint.x - 1)
        let boxWidth = min(preferredWidth, max(160, availableWidth))
        let minX = selection.minX + 1
        let maxX = max(minX, selection.maxX - boxWidth - 1)
        let origin = CGPoint(
            x: min(max(bodyPoint.x, minX), maxX),
            y: bodyPoint.y - TextEditingBox.headerHeight
        )
        let box = TextEditingBox(
            origin: origin,
            width: boxWidth,
            maxWidth: max(boxWidth, selection.width - 2),
            fontSize: fontSize,
            color: color,
            text: editingString
        )
        box.constrainOrigin = { [weak self] proposed, size in
            self?.constrainTextEditorOrigin(proposed, size: size) ?? proposed
        }
        box.onOriginChanged = { [weak self, weak box] in
            guard let self, let box else { return }
            self.updateTextEditorCapacity(box)
        }
        box.onTextChanged = { [weak self, weak box] in
            guard let self, let box else { return }
            self.updateTextEditorCapacity(box)
        }
        box.onCommit = { [weak self] in self?.commitTextEditing() }
        box.onCancel = { [weak self] in self?.cancelTextEditing() }

        addSubview(box)
        textEditingBox = box
        box.frame.origin = constrainTextEditorOrigin(box.frame.origin, size: box.frame.size)
        updateTextEditorCapacity(box)
        box.focusField()
        if existing != nil {
            box.setText(editingString, selectAll: true)
        }
        updateToolbarState()
        needsDisplay = true
    }

    func commitTextEditing() {
        guard let box = textEditingBox else { return }
        guard let selection else {
            removeTextEditorBox(box)
            return
        }
        let string = box.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyOrigin = box.bodyOrigin
        let origin = CGPoint(
            x: bodyOrigin.x - selection.minX,
            y: bodyOrigin.y - selection.minY
        )
        let fontSize = box.fontSize
        let color = box.color
        let editedID = editingTextID
        let undoSnapshot = textEditingUndoSnapshot
        removeTextEditorBox(box)

        if let editedID, let index = annotations.firstIndex(where: { $0.id == editedID }) {
            if string.isEmpty {
                if let undoSnapshot { pushUndoSnapshot(undoSnapshot) }
                annotations.remove(at: index)
                selectedTextID = nil
            } else {
                var updated = annotations[index]
                updated.kind = .text(origin: origin, string: string, fontSize: fontSize)
                updated.color = color
                if let undoSnapshot, updated != annotations[index] {
                    pushUndoSnapshot(undoSnapshot)
                }
                annotations[index] = updated
                selectedTextID = editedID
            }
        } else if !string.isEmpty {
            pushUndoSnapshot()
            let annotation = Annotation(
                kind: .text(origin: origin, string: string, fontSize: fontSize),
                color: color,
                lineWidth: currentLineWidth,
                filled: currentlyFilled
            )
            annotations.append(annotation)
            selectedTextID = annotation.id
        }

        currentFontSize = fontSize
        currentColor = color
        tool = .move
        window?.makeFirstResponder(self)
        updateToolbarState()
        needsDisplay = true
    }

    private func cancelTextEditing() {
        guard let box = textEditingBox else { return }
        removeTextEditorBox(box)
        window?.makeFirstResponder(self)
        updateToolbarState()
        needsDisplay = true
    }

    private func removeTextEditorBox(_ box: TextEditingBox) {
        box.onCommit = nil
        box.onCancel = nil
        box.onTextChanged = nil
        box.onOriginChanged = nil
        box.constrainOrigin = nil
        box.removeFromSuperview()
        textEditingBox = nil
        editingTextID = nil
        textEditingUndoSnapshot = nil
    }

    private func constrainTextEditorOrigin(_ proposed: CGPoint, size: CGSize) -> CGPoint {
        guard let selection else { return proposed }
        let minX = selection.minX + 1
        let maxX = max(minX, selection.maxX - size.width - 1)
        let bodyHeight = max(0, size.height - TextEditingBox.headerHeight)
        let minY = max(0, selection.minY - TextEditingBox.headerHeight)
        let maxY = max(minY, selection.maxY - bodyHeight - 1)
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    private func updateTextEditorCapacity(_ box: TextEditingBox) {
        guard let selection else { return }
        let availableWidth = max(80, selection.maxX - box.frame.minX - 1)
        box.setAvailableWidth(availableWidth)
        box.frame.origin = constrainTextEditorOrigin(box.frame.origin, size: box.frame.size)
    }

    private func applyColor(_ color: RGBAColor) {
        currentColor = color
        AppSettings.shared.toolColor = color
        if let box = textEditingBox {
            box.updateColor(color)
            box.focusField()
        } else if let selectedTextID,
                  let index = annotations.firstIndex(where: { $0.id == selectedTextID }) {
            if annotations[index].color != color {
                pushUndoSnapshot()
                annotations[index].color = color
                needsDisplay = true
            }
        }
        updateToolbarState()
        updateCursor(at: pointerLocation())
    }

    private func applyFontSize(_ size: CGFloat) {
        let clamped = TextMetrics.clampedFontSize(size)
        currentFontSize = clamped
        AppSettings.shared.toolFontSize = clamped
        if let box = textEditingBox {
            box.updateFontSize(clamped)
            box.frame.origin = constrainTextEditorOrigin(box.frame.origin, size: box.frame.size)
            updateTextEditorCapacity(box)
            box.focusField()
        } else if let selectedTextID,
                  let index = annotations.firstIndex(where: { $0.id == selectedTextID }),
                  case let .text(origin, string, currentSize) = annotations[index].kind {
            guard abs(currentSize - clamped) > 0.01 else {
                updateToolbarState()
                return
            }
            var newOrigin = origin
            if let selection {
                let textSize = TextMetrics.textRect(origin: .zero, string: string, fontSize: clamped).size
                newOrigin.x = min(newOrigin.x, max(0, selection.width - textSize.width))
                newOrigin.y = min(newOrigin.y, max(0, selection.height - textSize.height))
            }
            pushUndoSnapshot()
            annotations[index].kind = .text(origin: newOrigin, string: string, fontSize: clamped)
            needsDisplay = true
        }
        updateToolbarState()
    }

    // MARK: - Color

    // 取色按需单像素采样，不再预热整屏 RGBA 缓冲，放大镜开关与取色路径都无需分配大块内存。
    private func pixelColor(at localPoint: CGPoint) -> RGBAColor? {
        pixelSampler.prepare()
        let imagePoint = CGPoint(
            x: floor(min(max(localPoint.x, 0), bounds.width - 0.001) * captured.scale),
            y: floor(min(max(localPoint.y, 0), bounds.height - 0.001) * captured.scale)
        )
        return pixelSampler.color(at: imagePoint)
    }

    private func copyColorUnderCursor() {
        guard let point = pointerLocation() ?? selection.map({ CGPoint(x: $0.midX, y: $0.midY) }) else { return }
        guard let color = pixelColor(at: point) else { return }
        PasteboardWriter.writeText(color.hexString.uppercased())
        showToast("已复制颜色 \(color.hexString.uppercased())")
    }

    private func pickColor(at point: CGPoint) {
        guard !didPickColor, let color = pixelColor(at: point) else { return }
        didPickColor = true
        PasteboardWriter.writeText(color.hexString.uppercased())
        showToast("已复制颜色 \(color.hexString.uppercased())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            self.session?.canvas(self, didPickColor: color.hexString.uppercased())
        }
    }

    // MARK: - Toolbar

    private func showToolbar() {
        if toolbar == nil {
            let bar = EditorToolbarView()
            bar.delegate = self
            toolbar = bar
            addSubview(bar)
        }
        // 先取消隐藏再布局：layoutToolbar 会跳过隐藏中的工具栏，顺序反了会沿用旧选区的 frame
        toolbar?.isHidden = false
        layoutToolbar()
        updateToolbarState()
    }

    private func layoutToolbar() {
        guard let toolbar, !toolbar.isHidden, let selection else { return }
        let size = toolbar.intrinsicContentSize
        let margin: CGFloat = 8
        let gap: CGFloat = 12
        var x = min(max(margin, selection.maxX - size.width), bounds.width - size.width - margin)
        var y = selection.maxY + gap
        if y + size.height > bounds.height - margin {
            y = selection.minY - size.height - gap
        }
        if y < margin {
            y = min(bounds.height - size.height - margin, max(margin, selection.maxY - size.height - gap))
        }
        if bounds.width < size.width + margin * 2 {
            x = max(0, (bounds.width - size.width) / 2)
        }
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updateToolbarState() {
        toolbar?.update(
            tool: tool,
            color: currentColor,
            lineWidth: currentLineWidth,
            filled: currentlyFilled,
            fontSize: displayedTextFontSize,
            showsTextOptions: textEditingBox != nil || selectedTextAnnotation != nil,
            isTextEditing: textEditingBox != nil,
            canUndo: !undoStack.isEmpty,
            canRedo: !redoStack.isEmpty
        )
    }

    public func toolbar(_ toolbar: EditorToolbarView, perform action: EditorToolbarAction) {
        switch action {
        case let .selectColor(color):
            applyColor(color)
            return
        case let .selectFontSize(size):
            applyFontSize(size)
            return
        default:
            break
        }
        if textEditingBox != nil { commitTextEditing() }
        window?.makeFirstResponder(self)
        switch action {
        case let .selectTool(newTool):
            selectTool(newTool)
        case .selectColor, .selectFontSize:
            break
        case let .selectLineWidth(width):
            currentLineWidth = width
            AppSettings.shared.toolLineWidth = width
            updateToolbarState()
        case .toggleFill:
            currentlyFilled.toggle()
            AppSettings.shared.toolFilled = currentlyFilled
            updateToolbarState()
        case .undo:
            undoLastAnnotation()
        case .redo:
            redoLastAnnotation()
        case .copy:
            session?.canvasRequestCopy(self)
        case .save:
            session?.canvasRequestSave(self)
        case .pin:
            session?.canvasRequestPin(self)
        case .close:
            session?.cancel()
        }
    }

    // MARK: - Cursor

    private func updateCursor(at point: CGPoint?) {
        guard let point, bounds.contains(point) else { return }
        if mode == .colorPicker {
            NSCursor.crosshair.set()
            return
        }
        if let toolbar, !toolbar.isHidden, toolbar.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        if let selection {
            // 与手柄绘制条件一致：小选区无手柄热区
            if selection.width > 18, selection.height > 18,
               let handle = Geometry.handleHit(at: point, in: selection, tolerance: 8) {
                switch handle {
                case .left, .right:
                    NSCursor.resizeLeftRight.set()
                case .top, .bottom:
                    NSCursor.resizeUpDown.set()
                default:
                    NSCursor.crosshair.set()
                }
                return
            }
            if case .moving = dragState {
                NSCursor.closedHand.set()
                return
            }
            if case .movingText = dragState {
                NSCursor.closedHand.set()
                return
            }
            if selection.contains(point) {
                switch tool {
                case .move: NSCursor.openHand.set()
                case .text: NSCursor.iBeam.set()
                default: NSCursor.crosshair.set()
                }
                return
            }
        }
        NSCursor.crosshair.set()
    }

    // MARK: - Reset / export

    private func resetSelection() {
        selection = nil
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        selectedTextID = nil
        toolbar?.isHidden = true
        tool = initialTool
        needsDisplay = true
    }

    func prepareForExport() -> (selection: CGRect, annotations: [Annotation])? {
        if textEditingBox != nil { commitTextEditing() }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }
        return (selection, annotations)
    }

    func stopEditing() {
        if textEditingBox != nil { cancelTextEditing() }
    }

    private func clampPoint(_ point: CGPoint) -> CGPoint {
        Geometry.clampedPoint(point, to: bounds)
    }

    private func localPoint(_ viewPoint: CGPoint) -> CGPoint {
        guard let selection else { return viewPoint }
        return clampLocalPoint(CGPoint(x: viewPoint.x - selection.minX, y: viewPoint.y - selection.minY), in: selection)
    }

    private func clampLocalPoint(_ point: CGPoint, in selection: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), selection.width),
            y: min(max(point.y, 0), selection.height)
        )
    }

    func showToast(_ text: String) {
        toastText = text
        toastWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.toastText = nil
            self?.needsDisplay = true
        }
        toastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawDimming(context)
        if mode == .colorPicker {
            if let cursorPoint {
                drawCrosshair(at: cursorPoint, in: context)
                drawMagnifier(at: cursorPoint, in: context)
            }
            drawToast(in: context)
            return
        }

        if let hoveredWindow, selection == nil {
            drawWindowHighlight(hoveredWindow, in: context)
        }

        if let selection {
            drawSelectionAnnotations(selection, in: context)
            drawSelectionChrome(selection, in: context)
            drawSelectedTextChrome(in: context)
            // 拖选 / 手柄缩放 / 移动过程中也要看到实时尺寸与坐标，松手前就能对齐
            if tool != .text {
                drawSizeBadge(for: selection, in: context)
            }
        }

        if let cursorPoint {
            if selection == nil {
                drawCrosshair(at: cursorPoint, in: context)
            }
            if selection == nil || isCreatingSelection, AppSettings.shared.showMagnifier {
                drawMagnifier(at: cursorPoint, in: context)
            }
        }

        drawToast(in: context)
    }

    private var isCreatingSelection: Bool {
        if case .creating = dragState { return true }
        return false
    }

    private func drawDimming(_ context: CGContext) {
        NSColor.black.withAlphaComponent(selection == nil ? 0.22 : 0.42).setFill()
        guard let selection else {
            bounds.fill()
            return
        }
        let top = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, selection.minY))
        let bottom = CGRect(
            x: 0,
            y: selection.maxY,
            width: bounds.width,
            height: max(0, bounds.height - selection.maxY)
        )
        let left = CGRect(x: 0, y: selection.minY, width: max(0, selection.minX), height: selection.height)
        let right = CGRect(
            x: selection.maxX,
            y: selection.minY,
            width: max(0, bounds.width - selection.maxX),
            height: selection.height
        )
        for rect in [top, bottom, left, right] where rect.width > 0 && rect.height > 0 {
            rect.fill()
        }
        _ = context
    }

    private func drawSelectionAnnotations(_ selection: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: selection)
        context.translateBy(x: selection.minX, y: selection.minY)
        let source = RenderSource(
            image: captured.image,
            originInImage: Geometry.pixelRect(for: selection, scale: captured.scale).origin,
            pixelsPerPoint: captured.scale
        )
        var visibleAnnotations = annotations
        if let editingTextID {
            visibleAnnotations.removeAll { $0.id == editingTextID }
        }
        // 已提交标注缓存为位图层，鼠标移动/画笔拖动时不再全量重渲染；
        // 缓存仍由 AnnotationRenderer 生成，保证与导出一致
        let localRect = CGRect(origin: .zero, size: selection.size)

        if isSelectionGeometryChanging {
            // 选区移动/缩放中：缓存键必然失配（马赛克/模糊按 origin 采样底图），
            // 直接实时绘制，省掉每个鼠标事件重建整张选区位图的分配与拷贝；
            // 绘制顺序与像素输出与缓存路径完全一致（都走 AnnotationRenderer）
            AnnotationRenderer.draw(
                annotations: visibleAnnotations,
                in: context,
                selectionSize: selection.size,
                source: source,
                effectCache: effectCache
            )
        } else if let movingText = movingTextOverlay {
            // 拖动中的文字：已提交集合切成前后两段分别缓存，
            // 拖动过程中两段保持有效，整场拖动不重建位图；层叠顺序与提交后一致
            let index = visibleAnnotations.firstIndex { $0.id == movingText.id }
            let head = index.map { Array(visibleAnnotations[..<$0]) } ?? visibleAnnotations
            let tail = index.map { Array(visibleAnnotations[visibleAnnotations.index(after: $0)...]) } ?? []
            // 拖动期不再使用整张选区位图：释放它，常驻内存只与标注自身范围有关
            annotationCache = nil
            let (headTile, headCache) = annotationTileLayer(
                for: selection,
                annotations: head,
                cached: annotationCacheHead
            )
            annotationCacheHead = headCache
            if let headTile {
                drawAnnotationTile(headTile.image, origin: headTile.origin, in: context)
            }
            // 拖动中的文字走像素空间渲染：与已提交位图、导出同一 CTM，
            // 否则字形抗锯齿会有细微差异（所见即所得要求逐像素一致）
            if let textTile = renderAnnotationTile([movingText], selection: selection, source: source) {
                drawAnnotationTile(textTile.image, origin: textTile.origin, in: context)
            }
            let (tailTile, tailCache) = annotationTileLayer(
                for: selection,
                annotations: tail,
                cached: annotationCacheTail
            )
            annotationCacheTail = tailCache
            if let tailTile {
                drawAnnotationTile(tailTile.image, origin: tailTile.origin, in: context)
            }
        } else {
            let (layer, cache) = annotationLayer(for: selection, annotations: visibleAnnotations, cached: annotationCache)
            annotationCache = cache
            if let layer {
                AnnotationRenderer.drawImageTopLeft(layer, in: localRect, in: context)
            }
        }
        if let currentAnnotation {
            AnnotationRenderer.draw(
                annotation: currentAnnotation,
                in: context,
                source: source,
                effectCache: effectCache
            )
        }
        context.restoreGState()
    }

    /// 撤销栈深度（回归测试：编辑中「全选整屏」不得清空撤销栈）
    var undoStackCount: Int { undoStack.count }

    /// 选区几何正在变化：位图缓存的键包含完整选区，此时命中不了，直接实时绘制
    private var isSelectionGeometryChanging: Bool {
        switch dragState {
        case .moving, .resizing: return true
        default: return false
        }
    }

    // 缓存键必须覆盖渲染结果依赖的全部输入：完整选区（马赛克/模糊按 origin 采样底图，
    // 仅尺寸不变也会改变结果）与标注集合；captured 的图像和 scale 在画布生命周期内不变
    func committedAnnotationLayer(for selection: CGRect, visibleAnnotations: [Annotation]) -> CGImage? {
        let (image, cache) = annotationLayer(for: selection, annotations: visibleAnnotations, cached: annotationCache)
        annotationCache = cache
        return image
    }

    /// 渲染并缓存一段标注的位图层；返回新的缓存槽，由调用方持有
    private func annotationLayer(
        for selection: CGRect,
        annotations: [Annotation],
        cached: AnnotationCache?
    ) -> (image: CGImage?, cache: AnnotationCache?) {
        if let cached, cached.selection == selection, cached.annotations == annotations {
            return (cached.image, cached)
        }
        guard !annotations.isEmpty else {
            return (nil, nil)
        }
        let source = RenderSource(
            image: captured.image,
            originInImage: Geometry.pixelRect(for: selection, scale: captured.scale).origin,
            pixelsPerPoint: captured.scale
        )
        guard let image = renderAnnotationCache(annotations, selection: selection, source: source) else {
            return (nil, nil)
        }
        annotationLayerRenderCount += 1
        return (
            image,
            AnnotationCache(image: image, selection: selection, annotations: annotations, origin: .zero)
        )
    }

    /// 渲染并缓存一段标注的**瓦片**（按标注自身包围盒裁剪）。
    /// 常驻内存与标注实际范围成正比，而不是整张选区；瓦片原点对齐选区像素网格，
    /// 像素空间 CTM 与整图位图一致 → 与提交结果逐像素一致。
    private func annotationTileLayer(
        for selection: CGRect,
        annotations: [Annotation],
        cached: AnnotationCache?
    ) -> (tile: AnnotationCache?, cache: AnnotationCache?) {
        if let cached, cached.selection == selection, cached.annotations == annotations {
            return (cached, cached)
        }
        guard !annotations.isEmpty else {
            return (nil, nil)
        }
        let source = RenderSource(
            image: captured.image,
            originInImage: Geometry.pixelRect(for: selection, scale: captured.scale).origin,
            pixelsPerPoint: captured.scale
        )
        guard let rendered = renderAnnotationTile(annotations, selection: selection, source: source) else {
            return (nil, nil)
        }
        annotationLayerRenderCount += 1
        let cache = AnnotationCache(
            image: rendered.image,
            selection: selection,
            annotations: annotations,
            origin: rendered.origin
        )
        return (cache, cache)
    }

    /// 把瓦片按其选区局部原点贴回画布（上下文已平移到选区原点）
    private func drawAnnotationTile(_ image: CGImage, origin: CGPoint, in context: CGContext) {
        let scale = captured.scale
        let rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        AnnotationRenderer.drawImageTopLeft(image, in: rect, in: context)
    }

    /// 把一段标注渲染成小瓦片：与整张选区位图使用同一像素空间 CTM，
    /// 且瓦片原点对齐到选区像素网格，保证光栅化相位一致（逐像素可复现）。
    /// 用于拖动中的文字实时预览与前后两段，避免每个鼠标事件重建整张选区位图。
    private func renderAnnotationTile(
        _ annotations: [Annotation],
        selection: CGRect,
        source: RenderSource
    ) -> (image: CGImage, origin: CGPoint)? {
        guard !annotations.isEmpty else { return nil }
        let scale = captured.scale
        var bounds = CGRect.null
        for annotation in annotations {
            bounds = bounds.union(annotation.bounds)
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, scale > 0 else { return nil }
        // 外扩一点，避免描边与抗锯齿在瓦片边缘被裁掉
        bounds = bounds.insetBy(dx: -4, dy: -4)
        // 原点对齐到选区像素网格：相对选区原点偏移整像素，保证相位与整图位图一致
        let originX = (bounds.minX * scale).rounded(.down) / scale
        let originY = (bounds.minY * scale).rounded(.down) / scale
        let width = max(1, Int(((bounds.maxX - originX) * scale).rounded(.up)))
        let height = max(1, Int(((bounds.maxY - originY) * scale).rounded(.up)))
        let colorSpace = captured.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -originX, y: -originY)
        // 与整图位图路径等价：裁剪到选区范围（瓦片坐标 = 选区局部坐标 - origin）
        context.clip(to: CGRect(
            x: -originX,
            y: -originY,
            width: selection.width,
            height: selection.height
        ))
        for annotation in annotations {
            AnnotationRenderer.draw(
                annotation: annotation,
                in: context,
                source: source,
                effectCache: effectCache
            )
        }
        guard let image = context.makeImage() else { return nil }
        return (image, CGPoint(x: originX, y: originY))
    }

    func renderAnnotationCache(
        _ annotations: [Annotation],
        selection: CGRect,
        source: RenderSource
    ) -> CGImage? {
        let scale = captured.scale
        // 与导出裁剪（Geometry.pixelRect）逐边舍入一致，避免分数坐标/非整数 scale 下差 1px
        let pixelSize = Geometry.pixelRect(for: selection, scale: scale)
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))
        let colorSpace = captured.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        AnnotationRenderer.draw(
            annotations: annotations,
            in: context,
            selectionSize: selection.size,
            source: source,
            effectCache: effectCache
        )
        return context.makeImage()
    }

    private func drawSelectionChrome(_ selection: CGRect, in context: CGContext) {
        let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        NSColor.black.withAlphaComponent(0.4).setStroke()
        outline.lineWidth = 2
        outline.stroke()
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let crisp = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        crisp.lineWidth = 1
        crisp.stroke()

        if selection.width > 18, selection.height > 18, dragState.isNotMovingOrResizing {
            for (_, rect) in Geometry.handleRects(for: selection, size: 6.5) {
                let handlePath = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                NSColor.white.setFill()
                handlePath.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                handlePath.lineWidth = 1
                handlePath.stroke()
            }
        }
        _ = context
    }

    private func drawSelectedTextChrome(in context: CGContext) {
        guard textEditingBox == nil, let selection else { return }
        // 拖动中的文字位置以覆盖层为准：虚线选框必须跟随移动，否则会留在原位置
        guard let annotation = movingTextOverlay ?? selectedTextAnnotation,
              case let .text(origin, string, fontSize) = annotation.kind
        else { return }
        let textRect = TextMetrics.textRect(origin: origin, string: string, fontSize: fontSize)
            .offsetBy(dx: selection.minX, dy: selection.minY)
            .insetBy(dx: -4, dy: -4)
        let outline = NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4)
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.lineWidth = 1.5
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        outline.stroke()
        _ = context
    }

    private func drawSizeBadge(for selection: CGRect, in context: CGContext) {
        let pixelRect = Geometry.pixelRect(for: selection, scale: captured.scale)
        let width = max(1, Int(pixelRect.width))
        let height = max(1, Int(pixelRect.height))
        let text = "\(width) × \(height) px   @ \(Int(pixelRect.origin.x)), \(Int(pixelRect.origin.y))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let pillSize = CGSize(width: textSize.width + 18, height: textSize.height + 10)
        var x = selection.midX - pillSize.width / 2
        // 文案变长后窄画布也不能把 badge 推到负坐标被裁掉
        x = min(max(6, x), max(6, bounds.width - pillSize.width - 6))
        var y = selection.minY - pillSize.height - 7
        if y < 6 {
            y = selection.minY + 7
        }
        let pill = CGRect(x: x, y: y, width: pillSize.width, height: pillSize.height)
        NSColor(calibratedWhite: 0.08, alpha: 0.84).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: CGPoint(x: pill.minX + 9, y: pill.minY + 5),
            withAttributes: attributes
        )
        _ = context
    }

    private func drawWindowHighlight(_ window: DetectedWindow, in context: CGContext) {
        let rect = window.localRect.intersection(bounds)
        guard !rect.isNull else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let title = window.title
        let size = (title as NSString).size(withAttributes: attributes)
        var pill = CGRect(
            x: rect.minX + 8,
            y: rect.minY + 8,
            width: min(size.width + 16, bounds.width - 12),
            height: size.height + 8
        )
        if pill.maxX > bounds.maxX - 6 {
            pill.origin.x = bounds.maxX - pill.width - 6
        }
        NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        (title as NSString).draw(
            at: CGPoint(x: pill.minX + 8, y: pill.minY + 4),
            withAttributes: attributes
        )
        _ = context
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: point.x, y: 0))
        context.addLine(to: CGPoint(x: point.x, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: point.y))
        context.addLine(to: CGPoint(x: bounds.width, y: point.y))
        context.strokePath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(0.75)
        context.move(to: CGPoint(x: point.x + 0.25, y: 0))
        context.addLine(to: CGPoint(x: point.x + 0.25, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: point.y + 0.25))
        context.addLine(to: CGPoint(x: bounds.width, y: point.y + 0.25))
        context.strokePath()
        context.restoreGState()
    }

    /// 放大镜与信息条的联合区域：绘制与局部重绘脏区共用同一套几何，避免常量漂移留下残影。
    static func magnifierUnionRect(for cursor: CGPoint, in size: CGSize) -> CGRect {
        let loupeSize = CGSize(width: 126, height: 126)
        let infoHeight: CGFloat = 38
        let offset: CGFloat = 24
        var origin = CGPoint(x: cursor.x + offset, y: cursor.y + offset)
        if origin.x + loupeSize.width + 8 > size.width {
            origin.x = cursor.x - offset - loupeSize.width
        }
        let totalHeight = loupeSize.height + 6 + infoHeight
        if origin.y + totalHeight + 8 > size.height {
            origin.y = cursor.y - offset - totalHeight
        }
        origin.x = min(max(8, origin.x), size.width - loupeSize.width - 8)
        origin.y = min(max(8, origin.y), size.height - totalHeight - 8)
        return CGRect(x: origin.x, y: origin.y, width: loupeSize.width, height: totalHeight)
    }

    /// 十字线横贯全屏，脏区必须包含旧 / 新光标的整行整列；放大镜叠加精确联合区域。
    /// AppKit 会把 draw(_:) 裁剪到这些 rect，绘制逻辑无需改动。
    func cursorDirtyRects(old: CGPoint?, new: CGPoint) -> [CGRect] {
        let band: CGFloat = 3
        var rects: [CGRect] = []
        for point in ([old, new] as [CGPoint?]).compactMap({ $0 }) {
            rects.append(CGRect(x: point.x - band / 2, y: 0, width: band, height: bounds.height))
            rects.append(CGRect(x: 0, y: point.y - band / 2, width: bounds.width, height: band))
            if AppSettings.shared.showMagnifier {
                // 放大镜外描边 lineWidth 2，脏区外扩 2pt
                rects.append(Self.magnifierUnionRect(for: point, in: bounds.size).insetBy(dx: -2, dy: -2))
            }
        }
        return rects.map { $0.intersection(bounds) }.filter { !$0.isNull }
    }

    private func drawMagnifier(at cursor: CGPoint, in context: CGContext) {
        let scale = captured.scale
        let image = captured.image
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let cursorPixel = CGPoint(
            x: min(max(cursor.x * scale, 0), imageWidth - 1),
            y: min(max(cursor.y * scale, 0), imageHeight - 1)
        )
        let sourcePoints: CGFloat = 18
        var sourcePixels = sourcePoints * scale
        sourcePixels = min(sourcePixels, min(imageWidth, imageHeight))
        guard sourcePixels >= 2 else { return }
        var sourceRect = CGRect(
            x: cursorPixel.x - sourcePixels / 2,
            y: cursorPixel.y - sourcePixels / 2,
            width: sourcePixels,
            height: sourcePixels
        ).integral
        sourceRect.origin.x = min(max(0, sourceRect.minX), imageWidth - sourceRect.width)
        sourceRect.origin.y = min(max(0, sourceRect.minY), imageHeight - sourceRect.height)
        guard let crop = image.cropping(to: sourceRect) else { return }

        // 几何与局部重绘脏区共用 magnifierUnionRect，避免两处常量漂移
        let union = Self.magnifierUnionRect(for: cursor, in: bounds.size)
        let origin = union.origin
        let loupeSize = CGSize(width: union.width, height: 126)
        let infoHeight = union.height - loupeSize.height - 6
        let loupeRect = CGRect(origin: origin, size: loupeSize)

        context.saveGState()
        context.addPath(CGPath(roundedRect: loupeRect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.clip()
        context.interpolationQuality = .none
        AnnotationRenderer.drawImageTopLeft(crop, in: loupeRect, in: context)
        context.restoreGState()

        let scaleFactor = loupeRect.width / sourceRect.width
        let targetX = floor(cursorPixel.x)
        let targetY = floor(cursorPixel.y)
        let cell = CGRect(
            x: loupeRect.minX + (targetX - sourceRect.minX) * scaleFactor,
            y: loupeRect.minY + (targetY - sourceRect.minY) * scaleFactor,
            width: scaleFactor,
            height: scaleFactor
        )
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let cellPath = NSBezierPath(rect: cell.insetBy(dx: 0.25, dy: 0.25))
        cellPath.lineWidth = 1
        cellPath.stroke()

        NSColor.black.withAlphaComponent(0.5).setStroke()
        let shadowBorder = NSBezierPath(roundedRect: loupeRect.insetBy(dx: -1, dy: -1), xRadius: 10, yRadius: 10)
        shadowBorder.lineWidth = 2
        shadowBorder.stroke()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(roundedRect: loupeRect, xRadius: 9, yRadius: 9)
        border.lineWidth = 1
        border.stroke()

        // 像素缓冲由 pixelColor 统一预热：首次绘制不阻塞主线程，就绪前走单像素降级采样
        guard let color = pixelColor(at: cursor) else { return }
        let infoRect = CGRect(
            x: loupeRect.minX,
            y: loupeRect.maxY + 6,
            width: loupeRect.width,
            height: infoHeight
        )
        NSColor(calibratedWhite: 0.07, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: infoRect, xRadius: 7, yRadius: 7).fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        let infoBorder = NSBezierPath(roundedRect: infoRect, xRadius: 7, yRadius: 7)
        infoBorder.lineWidth = 1
        infoBorder.stroke()

        let swatch = CGRect(x: infoRect.minX + 8, y: infoRect.minY + 9, width: 20, height: 20)
        color.nsColor.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let swatchBorder = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
        swatchBorder.lineWidth = 1
        swatchBorder.stroke()

        let hexFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let hexAttributes: [NSAttributedString.Key: Any] = [
            .font: hexFont,
            .foregroundColor: NSColor.white,
        ]
        (color.hexString.uppercased() as NSString).draw(
            at: CGPoint(x: infoRect.minX + 34, y: infoRect.minY + 8),
            withAttributes: hexAttributes
        )
        let coordinateFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let coordinateAttributes: [NSAttributedString.Key: Any] = [
            .font: coordinateFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let coordinateText = "\(Int(targetX)), \(Int(targetY)) px   \(color.rgbDescription)"
        (coordinateText as NSString).draw(
            at: CGPoint(x: infoRect.minX + 34, y: infoRect.minY + 23),
            withAttributes: coordinateAttributes
        )
    }


    private func drawToast(in context: CGContext) {
        guard let toastText else { return }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (toastText as NSString).size(withAttributes: attributes)
        let pillSize = CGSize(width: textSize.width + 28, height: textSize.height + 16)
        let rect = CGRect(
            x: (bounds.width - pillSize.width) / 2,
            y: 54,
            width: pillSize.width,
            height: pillSize.height
        )
        NSColor.controlAccentColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        (toastText as NSString).draw(
            at: CGPoint(x: rect.minX + 14, y: rect.minY + 8),
            withAttributes: attributes
        )
        _ = context
    }

    // MARK: - Snapshot support

    public func configureForSnapshot(
        selection: CGRect?,
        annotations: [Annotation],
        tool: Tool,
        color: RGBAColor,
        lineWidth: CGFloat,
        filled: Bool,
        cursor: CGPoint? = nil,
        hoveredWindow: DetectedWindow? = nil,
        withToolbar: Bool = true,
        fontSize: CGFloat = AppSettings.shared.toolFontSize,
        textEditing: SnapshotTextEditing? = nil
    ) {
        self.selection = selection
        self.annotations = annotations
        self.undoStack = annotations.isEmpty ? [] : [[]]
        self.redoStack = []
        self.tool = tool
        self.currentColor = color
        self.currentLineWidth = lineWidth
        self.currentFontSize = fontSize
        self.currentlyFilled = filled
        self.cursorPoint = cursor
        self.hoveredWindow = hoveredWindow
        if selection != nil, withToolbar {
            showToolbar()
        } else {
            toolbar?.isHidden = true
        }
        if let textEditing, selection != nil {
            beginTextEditing(
                at: textEditing.origin,
                presetText: textEditing.text,
                presetFontSize: textEditing.fontSize
            )
        }
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }
}

private extension CanvasDragState {
    var isNotMovingOrResizing: Bool {
        switch self {
        case .moving, .resizing, .movingText: return false
        default: return true
        }
    }
}
