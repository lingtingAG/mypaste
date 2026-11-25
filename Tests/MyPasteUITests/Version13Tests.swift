import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MyPasteCore
@testable import MyPasteUI

/// v1.3 性能与存储优化的回归测试。
@MainActor
final class Version13Tests: XCTestCase {
    private var window: NSWindow!
    private var canvas: SelectionCanvasView!
    private var captured: CapturedScreen!
    private var originalFontSize: CGFloat = 20
    private var originalLastTool: Tool = .move

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        originalFontSize = AppSettings.shared.toolFontSize
        originalLastTool = AppSettings.shared.lastTool
        AppSettings.shared.lastTool = .move
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // 标注位图缓存按 captured.scale 渲染，视图 backing store 必须同缩放，
        // 否则缓存位图回绘时会被重采样，与实时绘制路径产生像素差
        let scale = window.backingScaleFactor
        captured = CapturedScreen(screen: screen, image: Self.makeImage(width: 1600, height: 1200), scale: scale)
        canvas = SelectionCanvasView(captured: captured, mode: .edit)
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas
    }

    override func tearDown() {
        AppSettings.shared.toolFontSize = originalFontSize
        AppSettings.shared.lastTool = originalLastTool
        window?.close()
        canvas = nil
        window = nil
        captured = nil
        super.tearDown()
    }

    // MARK: - 标注位图：拖动文字不应逐帧重建

    func testDraggingTextDoesNotRebuildAnnotationLayerPerFrame() throws {
        try prepareTextAnnotation()
        let committedBefore = try XCTUnwrap(canvas.annotations.first)
        guard case let .text(originBefore, _, _) = committedBefore.kind else {
            return XCTFail("Expected text annotation")
        }
        _ = try renderCanvas()
        let rendersBeforeDrag = canvas.annotationLayerRenderCount

        // 按下文字并连续拖动：每一步都强制重绘，标注位图不应随之重建
        sendMouse(.leftMouseDown, at: CGPoint(x: 205, y: 205), clickCount: 1)
        for step in 1...4 {
            sendMouse(.leftMouseDragged, at: CGPoint(x: 205 + step * 12, y: 205 + step * 6), clickCount: 1)
            _ = try renderCanvas()
        }
        // 拖动过程不改动已提交集合：这是「不逐帧重建」的前提
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations.first?.kind, committedBefore.kind)
        // 允许拖动开始时分段缓存各重建一次，之后必须命中缓存
        XCTAssertLessThanOrEqual(
            canvas.annotationLayerRenderCount,
            rendersBeforeDrag + 2,
            "拖动文字不应逐帧重建标注位图"
        )

        sendMouse(.leftMouseUp, at: CGPoint(x: 253, y: 229), clickCount: 1)
        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .text(origin, _, _) = try XCTUnwrap(canvas.annotations.first?.kind) else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertGreaterThan(origin.x, originBefore.x, "拖动结束后文字位置应落到已提交集合")
    }

    // MARK: - 快捷键与主菜单的冲突

    func testEditorShortcutsDoNotCollideWithMainMenu() throws {
        // 字符串层面的比对：编辑器组合键不得与主菜单撞车。
        // 真实分发路径由 testMainMenuDoesNotConsumeEditorShortcuts 覆盖
        // （直接问菜单「这个组合你吃吗」）。
        let menu = AppDelegate.makeMainMenu(target: nil)
        var menuCombos: Set<String> = []
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            for entry in submenu.items where !entry.keyEquivalent.isEmpty {
                menuCombos.insert("\(entry.keyEquivalent.lowercased())|\(entry.keyEquivalentModifierMask.rawValue)")
            }
        }

        // 这三个是安全共享：菜单动作与画布动作完全一致
        // （复制 ⌘C → 画布 copy(_:)，撤销 ⌘Z / 重做 ⇧⌘Z → 画布 undo(_:)/redo(_:)）
        let sharedWithSameAction: Set<String> = [
            "c|\(NSEvent.ModifierFlags.command.rawValue)",
            "z|\(NSEvent.ModifierFlags.command.rawValue)",
            "z|\(NSEvent.ModifierFlags([.command, .shift]).rawValue)",
        ]

        for entry in SelectionCanvasView.commandShortcuts {
            let combo = "\(entry.key)|\(entry.modifiers.rawValue)"
            if sharedWithSameAction.contains(combo) { continue }
            XCTAssertFalse(
                menuCombos.contains(combo),
                "编辑器组合键与主菜单冲突：\(SelectionCanvasView.shortcutLabel(key: entry.key, modifiers: entry.modifiers))"
            )
        }
    }

    func testMainMenuDoesNotConsumeEditorShortcuts() throws {
        // 真实分发路径：主菜单的快捷键在事件进入第一响应者之前就被消费。
        // 这里直接问菜单「这个组合你吃吗」，而不是比对字符串。
        let menu = AppDelegate.makeMainMenu(target: nil)
        let keyCodes: [Character: UInt16] = [
            "s": 1, "d": 2, "f": 3, "z": 6, "c": 8, "b": 11, "e": 14, "r": 15,
            "t": 17, "u": 32, "i": 34, "p": 35, "n": 45, "j": 38, "k": 40, "g": 5,
            "l": 37,
        ]
        // 与菜单共享且动作一致：复制 / 撤销 / 重做
        let sharedWithSameAction: Set<String> = [
            "c|\(NSEvent.ModifierFlags.command.rawValue)",
            "z|\(NSEvent.ModifierFlags.command.rawValue)",
            "z|\(NSEvent.ModifierFlags([.command, .shift]).rawValue)",
        ]

        for entry in SelectionCanvasView.commandShortcuts {
            let combo = "\(entry.key)|\(entry.modifiers.rawValue)"
            if sharedWithSameAction.contains(combo) { continue }
            guard let keyCode = keyCodes[entry.key.first!] else {
                XCTFail("缺少键码映射：\(entry.key)")
                continue
            }
            // 真实按键在带 Shift 时 characters 是大写（charactersIgnoringModifiers 仍是小写），
            // 菜单匹配用的是 characters：构造错会让"菜单吃掉了组合键"变成假象
            let typed = entry.modifiers.contains(.shift)
                ? String(entry.key).uppercased()
                : String(entry.key)
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: entry.modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: typed,
                charactersIgnoringModifiers: String(entry.key),
                isARepeat: false,
                keyCode: keyCode
            ) else {
                XCTFail("无法构造按键事件：\(entry.key)")
                continue
            }
            XCTAssertFalse(
                menu.performKeyEquivalent(with: event),
                "主菜单会消费 \(SelectionCanvasView.shortcutLabel(key: entry.key, modifiers: entry.modifiers))，画布收不到"
            )
        }
    }

    func testSelectAllDoesNotWipeAnnotationsWhileEditing() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15, modifiers: .command)
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(canvas.annotations.count, 1)

        // 编辑中触发「全选」不得清空标注与撤销栈
        canvas.selectAll(nil)
        XCTAssertEqual(canvas.annotations.count, 1, "编辑中全选不得丢弃标注")
        XCTAssertTrue(canvas.undoStackCount > 0, "编辑中全选不得清空撤销栈")
    }

    // MARK: - 设置窗口的使用说明

    func testUsageGuideRefreshesRightAfterRecordingShortcut() throws {
        let suite = "com.mypaste.tests.prefs.v13"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = PreferencesWindowController(settings: settings, onHotkeysChanged: { [] })
        _ = controller.makeSnapshotContentView()

        let before = controller.usageIntroText
        XCTAssertTrue(before.contains(settings.captureShortcut.displayString), "说明应包含当前截图快捷键")

        // 模拟录制完成：新快捷键写入后说明必须立刻刷新，而不是等重新打开窗口
        let recorded = Shortcut(keyCode: 37, modifiers: UInt32(cmdKey | optionKey))
        controller.captureRecorder?.onRecord?(recorded)

        let after = controller.usageIntroText
        XCTAssertNotEqual(before, after, "录制新快捷键后使用说明必须立即刷新")
        XCTAssertTrue(after.contains(recorded.displayString), "说明应包含刚录制的快捷键")
        XCTAssertEqual(settings.captureShortcut, recorded)
    }

    // MARK: - 工具栏外观

    func testToolbarContentFitsPanelAndAllSymbolsResolve() throws {
        let toolbar = EditorToolbarView()
        toolbar.update(
            tool: .move,
            color: .red,
            lineWidth: 4,
            filled: false,
            fontSize: 20,
            showsTextOptions: false,
            isTextEditing: false,
            canUndo: false,
            canRedo: false
        )
        toolbar.frame = NSRect(x: 0, y: 0, width: 544, height: toolbar.intrinsicContentSize.height)
        toolbar.layoutSubtreeIfNeeded()
        // 移除底部说明行后若面板高度写死过小，复制等按钮会溢出圆角面板
        XCTAssertTrue(toolbar.contentFitsPanel, "工具栏内容不能溢出面板")
        // 符号解析失败时按钮会画出系统本地化名称（例如出现「格式」字样）
        XCTAssertEqual(toolbar.missingToolSymbolCount, 0, "所有工具按钮都必须有可用符号")

        // 撤销 / 重做提示必须来自命令表，不能硬编码
        let undoLabel = SelectionCanvasView.shortcutLabel(key: "z", modifiers: [.command])
        let redoLabel = SelectionCanvasView.shortcutLabel(key: "z", modifiers: [.command, .shift])
        XCTAssertTrue(toolbar.buttonTooltips.contains("撤销 (\(undoLabel))"), "撤销提示应来自命令表")
        XCTAssertTrue(toolbar.buttonTooltips.contains("重做 (\(redoLabel))"), "重做提示应来自命令表")
    }

    // MARK: - 快捷键统一为 ⌘ 组合

    func testEditorToolShortcutsRequireCommandModifier() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        XCTAssertEqual(canvas.tool, .move)

        // 单字母不再切换工具：所有按钮统一用 ⌘ 组合
        press("r", keyCode: 15)
        XCTAssertNotEqual(canvas.tool, .rectangle, "单字母快捷键应已停用")

        press("r", keyCode: 15, modifiers: .command)
        XCTAssertEqual(canvas.tool, .rectangle)
        press("n", keyCode: 45, modifiers: .command)
        XCTAssertEqual(canvas.tool, .number)
        press("i", keyCode: 34, modifiers: .command)
        XCTAssertEqual(canvas.tool, .marker)
        press("d", keyCode: 2, modifiers: .command)
        XCTAssertEqual(canvas.tool, .mosaic)
        // 与编辑菜单撞车的三个工具改用主菜单未占用的字母：移动 / 箭头 / 橡皮擦
        press("g", keyCode: 5, modifiers: .command)
        XCTAssertEqual(canvas.tool, .move)
        press("j", keyCode: 38, modifiers: .command)
        XCTAssertEqual(canvas.tool, .arrow)
        press("k", keyCode: 40, modifiers: .command)
        XCTAssertEqual(canvas.tool, .eraser)
    }

    // MARK: - 贴图菜单：隐藏与删除是两件事

    func testPinMenuDistinguishesHideFromDelete() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let pin = PinWindowController(
            image: Self.makeImage(width: 40, height: 30),
            frame: NSRect(x: 0, y: 0, width: 40, height: 30),
            originalText: nil
        )
        defer { pin.closePin() }
        _ = screen
        let view = try XCTUnwrap(pin.window?.contentView as? PinContentView)
        let titles = view.makeContextMenu().items.map(\.title)
        XCTAssertTrue(
            titles.contains { $0.hasPrefix("隐藏贴图") },
            "隐藏贴图应保留：只是收起，可从菜单栏恢复"
        )
        XCTAssertTrue(titles.contains("删除贴图"), "应提供明确的删除贴图入口")
        XCTAssertFalse(titles.contains("关闭贴图"), "旧的「关闭贴图」命名应被删除贴图取代")
    }

    // MARK: - 拖动期常驻内存：与标注范围成正比，而不是整张选区

    func testTextDragKeepsCachedTilesSmall() throws {
        try prepareTextAnnotation()
        // 选区 400×300 pt @2x = 240,000 px；拖字期间常驻的只是文字瓦片
        let selectionPixels = 400 * 300 * 4

        sendMouse(.leftMouseDown, at: CGPoint(x: 205, y: 205), clickCount: 1)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 260, y: 240), clickCount: 1)
        _ = try renderCanvas()

        XCTAssertLessThan(
            canvas.cachedTilePixelCount,
            selectionPixels / 4,
            "拖字常驻的瓦片应远小于整张选区位图"
        )
        sendMouse(.leftMouseUp, at: CGPoint(x: 260, y: 240), clickCount: 1)
    }

    // MARK: - 所见即所得：拖动预览与提交结果必须一致
    func testTextDragPreviewMatchesCommittedResult() throws {
        try prepareTextAnnotation()
        // 再加一个矩形压住文字，强制走「前段 + 拖动文字 + 后段」的分段路径
        press("r", keyCode: 15, modifiers: .command)
        drag(from: CGPoint(x: 180, y: 180), to: CGPoint(x: 320, y: 260))
        press("g", keyCode: 5, modifiers: .command)

        sendMouse(.leftMouseDown, at: CGPoint(x: 205, y: 205), clickCount: 1)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 260, y: 240), clickCount: 1)
        let preview = try renderCanvas()

        sendMouse(.leftMouseUp, at: CGPoint(x: 260, y: 240), clickCount: 1)
        let committed = try renderCanvas()

        XCTAssertEqual(preview.width, committed.width)
        XCTAssertEqual(preview.height, committed.height)
        // 只比较选区内部：选区边框与缩放手柄属于交互 UI，拖动中隐藏、松手后出现，
        // 与标注渲染无关（见 CanvasDragState.isNotMovingOrResizing）
        let selection = try XCTUnwrap(canvas.selection)
        let inner = selection.insetBy(dx: 12, dy: 12)
        let previewSampler = PixelSampler(image: preview)
        let committedSampler = PixelSampler(image: committed)
        var mismatches = 0
        var samples: [String] = []
        for y in stride(from: Int(inner.minY * 2), to: Int(inner.maxY * 2), by: 2) {
            for x in stride(from: Int(inner.minX * 2), to: Int(inner.maxX * 2), by: 2) {
                let a = previewSampler.color(at: CGPoint(x: x, y: y))
                let b = committedSampler.color(at: CGPoint(x: x, y: y))
                if a != b {
                    mismatches += 1
                    if samples.count < 4 {
                        samples.append("(\(x),\(y)) 预览=\(describe(a)) 提交=\(describe(b))")
                    }
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "拖动预览必须与提交后的标注渲染逐像素一致；样例：\(samples.joined(separator: " | "))")
    }

    // MARK: - 移动选区不应重建标注位图

    func testMovingSelectionDoesNotRebuildAnnotationLayer() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15, modifiers: .command)
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 250))
        _ = try renderCanvas()
        let rendersBeforeMove = canvas.annotationLayerRenderCount

        // 移动工具下拖动选区：缓存键必然失配，改为实时绘制，不重建位图
        sendMouse(.leftMouseDown, at: CGPoint(x: 400, y: 380), clickCount: 1)
        for step in 1...3 {
            sendMouse(.leftMouseDragged, at: CGPoint(x: 400 - step * 10, y: 380 - step * 8), clickCount: 1)
            _ = try renderCanvas()
        }
        XCTAssertEqual(
            canvas.annotationLayerRenderCount,
            rendersBeforeMove,
            "移动选区不应重建标注位图"
        )
        sendMouse(.leftMouseUp, at: CGPoint(x: 370, y: 356), clickCount: 1)
    }

    // MARK: - 保存路径：PNG 只编码一次

    func testSavedPNGDataIsReusableForHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPaste-v13-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = Self.makeImage(width: 64, height: 48)
        // write 返回已编码数据：历史库复用同一份字节，不再二次编码整图
        let data = try ImageExporter.write(image, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data, "写盘内容必须与返回的编码数据一致")

        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let pngResult = CaptureResult(
            image: image,
            screen: screen,
            screenRect: .zero,
            scale: 2,
            encoded: EncodedCapture(data: data, fileExtension: "png")
        )
        XCTAssertEqual(pngResult.reusablePNGData, data, "PNG 编码结果必须可被历史库复用")

        // 非 PNG 格式不能当作历史库 PNG 复用
        let jpegResult = CaptureResult(
            image: image,
            screen: screen,
            screenRect: .zero,
            scale: 2,
            encoded: EncodedCapture(data: Data([0x01, 0x02]), fileExtension: "jpg")
        )
        XCTAssertNil(jpegResult.reusablePNGData)
        // 扩展名是 png 但内容不是 PNG：签名校验必须拦下
        let forgedResult = CaptureResult(
            image: image,
            screen: screen,
            screenRect: .zero,
            scale: 2,
            encoded: EncodedCapture(data: Data([0x01, 0x02, 0x03, 0x04]), fileExtension: "png")
        )
        XCTAssertNil(forgedResult.reusablePNGData, "扩展名与内容不符的数据不能当作历史库原图")
        // 未保存过的结果没有可复用数据
        let plainResult = CaptureResult(image: image, screen: screen, screenRect: .zero, scale: 2)
        XCTAssertNil(plainResult.reusablePNGData)
    }

    // MARK: - Helpers

    private func describe(_ color: RGBAColor?) -> String {
        guard let color else { return "nil" }
        return String(format: "r=%.3f g=%.3f b=%.3f a=%.3f", color.red, color.green, color.blue, color.alpha)
    }

    /// 建立一个选区并提交一段文字标注
    private func prepareTextAnnotation() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("t", keyCode: 17, modifiers: .command)
        click(at: CGPoint(x: 200, y: 200))
        let box = try XCTUnwrap(canvas.textEditingBox)
        box.textField.stringValue = "Drag me"
        canvas.commitTextEditing()
        XCTAssertEqual(canvas.annotations.count, 1)
    }

    private func renderCanvas() throws -> CGImage {
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        return try XCTUnwrap(rep.cgImage)
    }

    private func drag(from: CGPoint, to: CGPoint) {
        sendMouse(.leftMouseDown, at: from, clickCount: 1)
        sendMouse(.leftMouseDragged, at: to, clickCount: 1)
        sendMouse(.leftMouseUp, at: to, clickCount: 1)
    }

    private func click(at point: CGPoint) {
        sendMouse(.leftMouseDown, at: point, clickCount: 1)
        sendMouse(.leftMouseUp, at: point, clickCount: 1)
    }

    private func press(_ character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Failed to create key event")
            return
        }
        canvas.keyDown(with: event)
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int) {
        guard let event = makeMouseEvent(type, at: point, clickCount: clickCount) else {
            XCTFail("Failed to create mouse event")
            return
        }
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: break
        }
    }

    private func makeMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int) -> NSEvent? {
        let windowPoint = CGPoint(x: point.x, y: (window.contentView?.bounds.height ?? 600) - point.y)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )
    }

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.19, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fill(CGRect(x: 100, y: 100, width: 400, height: 300))
        return context.makeImage()!
    }
}
