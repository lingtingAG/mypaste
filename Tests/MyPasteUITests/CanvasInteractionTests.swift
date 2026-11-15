import AppKit
import XCTest
@testable import MyPasteCore
@testable import MyPasteUI

@MainActor
final class CanvasInteractionTests: XCTestCase {
    private var window: NSWindow!
    private var canvas: SelectionCanvasView!
    private var captured: CapturedScreen!
    // 工具栏动作会写 AppSettings.shared（UserDefaults.standard 的测试域），结束时还原避免污染后续运行
    private var originalFontSize: CGFloat = 20

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        originalFontSize = AppSettings.shared.toolFontSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let image = Self.makeImage(width: 1600, height: 1200)
        captured = CapturedScreen(screen: screen, image: image, scale: 2)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        canvas = SelectionCanvasView(captured: captured, mode: .edit)
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas
    }

    override func tearDown() {
        AppSettings.shared.toolFontSize = originalFontSize
        window?.close()
        canvas = nil
        window = nil
        captured = nil
        super.tearDown()
    }

    func testMenuBarIconIsTemplateAndCorrectSize() {
        let image = MenuBarIcon.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
        XCTAssertNotNil(image.tiffRepresentation)
    }

    func testDragCreatesSelectionAndShowsToolbar() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        XCTAssertEqual(canvas.selection, CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertTrue(canvas.subviews.contains { $0 is EditorToolbarView })
    }

    func testClickWithoutDragSelectsWholeScreen() {
        click(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(canvas.selection, CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testDrawingRectangleCreatesAnnotation() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15)
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 250))

        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .rectangle(rect) = canvas.annotations[0].kind else {
            return XCTFail("Expected rectangle")
        }
        XCTAssertEqual(rect.minX, 50, accuracy: 0.5)
        XCTAssertEqual(rect.minY, 50, accuracy: 0.5)
        XCTAssertEqual(rect.width, 150, accuracy: 0.5)
        XCTAssertEqual(rect.height, 100, accuracy: 0.5)
    }

    func testUndoAndRedo() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15)
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 250))
        canvas.undo(nil)
        XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.redo(nil)
        XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testNumberAndEraser() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("n", keyCode: 45)
        click(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(canvas.annotations.count, 1)
        if case let .number(_, value) = canvas.annotations[0].kind {
            XCTAssertEqual(value, 1)
        } else {
            XCTFail("Expected number annotation")
        }
        press("x", keyCode: 7)
        click(at: CGPoint(x: 200, y: 200))
        XCTAssertTrue(canvas.annotations.isEmpty)
    }

    func testTextEditingCommitsAnnotation() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("t", keyCode: 17)
        click(at: CGPoint(x: 200, y: 200))
        let box = try XCTUnwrap(canvas.textEditingBox)
        box.textField.stringValue = "Hello MyPaste"
        canvas.commitTextEditing()

        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .text(_, string, _) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(string, "Hello MyPaste")
        XCTAssertEqual(canvas.tool, .move)
        XCTAssertEqual(canvas.selectedTextID, canvas.annotations[0].id)
    }

    func testFontSizeAppliesToEditingAndCommittedText() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("t", keyCode: 17)
        click(at: CGPoint(x: 200, y: 200))
        let box = try XCTUnwrap(canvas.textEditingBox)
        box.textField.stringValue = "Hello"

        canvas.toolbar(EditorToolbarView(), perform: .selectFontSize(32))
        XCTAssertNotNil(canvas.textEditingBox)
        XCTAssertEqual(box.fontSize, 32, accuracy: 0.01)
        XCTAssertEqual(box.textField.font?.pointSize ?? 0, 32, accuracy: 0.01)

        canvas.commitTextEditing()
        guard case let .text(_, _, committedSize) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(committedSize, 32, accuracy: 0.01)

        canvas.toolbar(EditorToolbarView(), perform: .selectFontSize(18))
        guard case let .text(_, _, resized) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(resized, 18, accuracy: 0.01)

        canvas.undo(nil)
        guard case let .text(_, _, restored) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(restored, 32, accuracy: 0.01)
    }

    func testDraggingInputBoxHeaderMovesText() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("t", keyCode: 17)
        click(at: CGPoint(x: 200, y: 200))
        let box = try XCTUnwrap(canvas.textEditingBox)
        box.textField.stringValue = "Hello MyPaste"

        let originalOrigin = box.frame.origin
        let header = CGPoint(x: originalOrigin.x + 20, y: originalOrigin.y + 8)
        drag(view: box, from: header, to: CGPoint(x: header.x + 30, y: header.y + 20))

        XCTAssertEqual(box.frame.origin.x, originalOrigin.x + 30, accuracy: 0.5)
        XCTAssertEqual(box.frame.origin.y, originalOrigin.y + 20, accuracy: 0.5)

        canvas.commitTextEditing()
        guard case let .text(origin, _, _) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(origin.x, 130, accuracy: 0.5)
        XCTAssertEqual(origin.y, 120, accuracy: 0.5)
    }

    func testCommittedTextCanBeMovedAndEdited() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("t", keyCode: 17)
        click(at: CGPoint(x: 200, y: 200))
        let box = try XCTUnwrap(canvas.textEditingBox)
        box.textField.stringValue = "Hello MyPaste"
        canvas.commitTextEditing()

        drag(from: CGPoint(x: 220, y: 220), to: CGPoint(x: 270, y: 250))
        guard case let .text(origin, _, fontSize) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(origin.x, 150, accuracy: 0.5)
        XCTAssertEqual(origin.y, 130, accuracy: 0.5)

        let textRect = TextMetrics.textRect(origin: origin, string: "Hello MyPaste", fontSize: fontSize)
        let center = CGPoint(x: 100 + textRect.midX, y: 100 + textRect.midY)
        click(at: center)
        sendMouse(.leftMouseDown, at: center, clickCount: 2)
        sendMouse(.leftMouseUp, at: center, clickCount: 2)

        let editor = try XCTUnwrap(canvas.textEditingBox)
        XCTAssertEqual(editor.textField.stringValue, "Hello MyPaste")
        editor.textField.stringValue = "Updated"
        canvas.commitTextEditing()

        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .text(updatedOrigin, updatedString, _) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(updatedString, "Updated")
        XCTAssertEqual(updatedOrigin, origin)
    }

    func testResizeSelectionWithHandle() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 500, y: 450))
        let selection = canvas.selection!
        XCTAssertEqual(selection.minX, 100, accuracy: 0.5)
        XCTAssertEqual(selection.minY, 100, accuracy: 0.5)
        XCTAssertEqual(selection.width, 400, accuracy: 0.5)
        XCTAssertEqual(selection.height, 350, accuracy: 0.5)
    }

    func testThinDragKeepsUserSelection() throws {
        // 宽/高不足 8pt 的有意细长拖选不应被替换为全屏选区
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 105))
        let selection = try XCTUnwrap(canvas.selection)
        XCTAssertEqual(selection.minX, 100, accuracy: 0.5)
        XCTAssertEqual(selection.minY, 100, accuracy: 0.5)
        XCTAssertEqual(selection.width, 200, accuracy: 0.5)
        XCTAssertEqual(selection.height, 8, accuracy: 0.5)
    }

    func testToolbarRelayoutsAfterReselecting() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbarView }.first)
        let firstFrame = toolbar.frame

        // 选区外按下会先隐藏工具栏，再拖出新选区；工具栏必须按新选区重新布局
        drag(from: CGPoint(x: 500, y: 450), to: CGPoint(x: 700, y: 550))
        XCTAssertEqual(try XCTUnwrap(canvas.selection), CGRect(x: 500, y: 450, width: 200, height: 100))
        XCTAssertNotEqual(toolbar.frame, firstFrame)
        XCTAssertEqual(toolbar.frame.maxX, 700, accuracy: 0.5)
        XCTAssertLessThan(toolbar.frame.maxY, 450)
    }

    func testArrowNudgeCoalescesIntoOneUndoStep() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("t", keyCode: 17)
        click(at: CGPoint(x: 200, y: 200))
        let box = try XCTUnwrap(canvas.textEditingBox)
        box.textField.stringValue = "Nudge"
        canvas.commitTextEditing()

        guard case let .text(original, _, fontSize) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        let textRect = TextMetrics.textRect(origin: original, string: "Nudge", fontSize: fontSize)
        click(at: CGPoint(x: 100 + textRect.midX, y: 100 + textRect.midY))

        sendKey(keyCode: 124)
        sendKey(keyCode: 124)
        sendKey(keyCode: 124)
        guard case let .text(nudged, _, _) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(nudged.x, original.x + 3, accuracy: 0.5)

        // 连续方向键微调合并为一条撤销记录：一次撤销回到起点且不删除文字
        canvas.undo(nil)
        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .text(restored, _, _) = canvas.annotations[0].kind else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(restored.x, original.x, accuracy: 0.5)
    }

    func testPrepareForExportComposesAnnotations() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15)
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 250))
        let prepared = try XCTUnwrap(canvas.prepareForExport())
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: captured.image,
            selectionRect: prepared.selection,
            screenScale: captured.scale,
            annotations: prepared.annotations
        ))
        XCTAssertEqual(composed.width, 800)
        XCTAssertEqual(composed.height, 600)
    }

    func testEffectiveScaleDerivesFromImage() {
        // HiDPI 缩放分辨率：图像实际像素与 backingScaleFactor 推算不一致时以图像为准
        XCTAssertEqual(
            CapturedScreen.effectiveScale(imageWidth: 3840, frameWidth: 1920, fallback: 2),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturedScreen.effectiveScale(imageWidth: 2560, frameWidth: 1440, fallback: 2),
            2560.0 / 1440.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturedScreen.effectiveScale(imageWidth: 1800, frameWidth: 1440, fallback: 2),
            1.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturedScreen.effectiveScale(imageWidth: 0, frameWidth: 1440, fallback: 2),
            2,
            accuracy: 0.001
        )
    }

    func testPenDrawingCollectsPoints() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("b", keyCode: 11)
        sendMouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), clickCount: 1)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 200, y: 180), clickCount: 1)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 260, y: 200), clickCount: 1)
        sendMouse(.leftMouseUp, at: CGPoint(x: 260, y: 200), clickCount: 1)
        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .pen(points) = canvas.annotations[0].kind else {
            return XCTFail("Expected pen annotation")
        }
        XCTAssertGreaterThanOrEqual(points.count, 3)
    }

    func testShiftConstrainsSquareAndArrowAngle() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15)
        sendMouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), clickCount: 1, modifiers: .shift)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 300, y: 210), clickCount: 1, modifiers: .shift)
        sendMouse(.leftMouseUp, at: CGPoint(x: 300, y: 210), clickCount: 1, modifiers: .shift)
        guard case let .rectangle(rect) = canvas.annotations[0].kind else {
            return XCTFail("Expected rectangle")
        }
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.5)

        press("a", keyCode: 0)
        sendMouse(.leftMouseDown, at: CGPoint(x: 150, y: 300), clickCount: 1, modifiers: .shift)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 300, y: 320), clickCount: 1, modifiers: .shift)
        sendMouse(.leftMouseUp, at: CGPoint(x: 300, y: 320), clickCount: 1, modifiers: .shift)
        guard case let .arrow(from, to) = canvas.annotations[1].kind else {
            return XCTFail("Expected arrow")
        }
        let angle = atan2(to.y - from.y, to.x - from.x) * 180 / .pi
        XCTAssertEqual(angle.truncatingRemainder(dividingBy: 45), 0, accuracy: 0.5)
    }

    func testRightClickCancelsStrokeButKeepsSession() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15)
        sendMouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), clickCount: 1)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 300, y: 250), clickCount: 1)
        canvas.rightMouseDown(with: NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!)
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertNotNil(canvas.selection)
        // 会话未取消：仍可继续绘制
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 220))
        XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testArrowKeysNudgeSelection() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        sendKey(keyCode: 124)
        sendKey(keyCode: 125)
        let selection = try XCTUnwrap(canvas.selection)
        XCTAssertEqual(selection.origin.x, 101, accuracy: 0.5)
        XCTAssertEqual(selection.origin.y, 101, accuracy: 0.5)
        sendKey(keyCode: 123, modifiers: .option)
        XCTAssertEqual(try XCTUnwrap(canvas.selection).origin.x, 91, accuracy: 0.5)
    }

    func testUndoStackCappedAt50() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 550))
        press("n", keyCode: 45)
        for index in 0..<55 {
            click(at: CGPoint(x: 120 + CGFloat(index) * 8, y: 150))
        }
        XCTAssertEqual(canvas.annotations.count, 55)
        for _ in 0..<50 { canvas.undo(nil) }
        XCTAssertEqual(canvas.annotations.count, 5)
        canvas.undo(nil)
        XCTAssertEqual(canvas.annotations.count, 5)
    }

    func testCachedAnnotationLayerRendersSameAsDirect() throws {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        press("r", keyCode: 15)
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 350, y: 280))
        press("n", keyCode: 45)
        click(at: CGPoint(x: 420, y: 350))

        func renderCanvas() throws -> CGImage {
            let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            return try XCTUnwrap(rep.cgImage)
        }

        // 第一次渲染建立缓存位图层，第二次走缓存路径；两者必须像素一致
        let first = try renderCanvas()
        let second = try renderCanvas()
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        let firstSampler = PixelSampler(image: first)
        let secondSampler = PixelSampler(image: second)
        var mismatches = 0
        for y in stride(from: 0, to: first.height, by: 3) {
            for x in stride(from: 0, to: first.width, by: 3) {
                let a = firstSampler.color(at: CGPoint(x: x, y: y))
                let b = secondSampler.color(at: CGPoint(x: x, y: y))
                if a != b { mismatches += 1 }
            }
        }
        XCTAssertEqual(mismatches, 0)

        // 缓存位图本身与导出合成器渲染的标注层一致（所见即所得）
        let selection = try XCTUnwrap(canvas.selection)
        let source = RenderSource(
            image: captured.image,
            originInImage: CGPoint(x: selection.minX * captured.scale, y: selection.minY * captured.scale),
            pixelsPerPoint: captured.scale
        )
        let cacheImage = try XCTUnwrap(canvas.renderAnnotationCache(
            canvas.annotations,
            selection: selection,
            source: source
        ))
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: captured.image,
            selectionRect: selection,
            screenScale: captured.scale,
            annotations: canvas.annotations
        ))
        XCTAssertEqual(cacheImage.width, composed.width)
        XCTAssertEqual(cacheImage.height, composed.height)
        // 序号圆心局部坐标 (320, 250)：中心被白色数字覆盖，取圆内左侧纯色区域；
        // 抽样多点而非单点，避免单点偶然一致掩盖渲染差异
        let cacheSampler = PixelSampler(image: cacheImage)
        let composedSampler = PixelSampler(image: composed)
        let expected = canvas.annotations[1].color
        for offsetY in stride(from: -4, through: 4, by: 2) {
            let dotPoint = CGPoint(x: 310 * captured.scale, y: (250 + CGFloat(offsetY)) * captured.scale)
            let cacheColor = try XCTUnwrap(cacheSampler.color(at: dotPoint))
            let composedColor = try XCTUnwrap(composedSampler.color(at: dotPoint))
            XCTAssertEqual(cacheColor.red, expected.red, accuracy: 0.08)
            XCTAssertEqual(cacheColor.green, expected.green, accuracy: 0.08)
            XCTAssertEqual(cacheColor.blue, expected.blue, accuracy: 0.08)
            XCTAssertEqual(composedColor.red, cacheColor.red, accuracy: 0.02)
            XCTAssertEqual(composedColor.green, cacheColor.green, accuracy: 0.02)
            XCTAssertEqual(composedColor.blue, cacheColor.blue, accuracy: 0.02)
        }
    }

    func testMovingSelectionResamplesMosaicCache() throws {
        // 底图左半红、右半蓝（像素坐标），马赛克效果依赖选区 origin 采样
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1600,
            height: 1200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 800, y: 0, width: 800, height: 1200))
        let splitImage = try XCTUnwrap(context.makeImage())
        captured = CapturedScreen(screen: NSScreen.main ?? NSScreen.screens[0], image: splitImage, scale: 2)
        canvas = SelectionCanvasView(captured: captured, mode: .edit)
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas

        let mosaic = Annotation(kind: .mosaic(CGRect(x: 0, y: 0, width: 200, height: 200)), color: .red, lineWidth: 4)
        let redSelection = CGRect(x: 100, y: 100, width: 200, height: 200)
        canvas.configureForSnapshot(
            selection: redSelection,
            annotations: [mosaic],
            tool: .move,
            color: .red,
            lineWidth: 4,
            filled: false,
            withToolbar: false
        )
        let samplePoint = CGPoint(x: 200, y: 200)
        let first = try XCTUnwrap(canvas.committedAnnotationLayer(for: redSelection, visibleAnnotations: canvas.annotations))
        let firstColor = try XCTUnwrap(PixelSampler(image: first).color(at: samplePoint))
        XCTAssertGreaterThan(firstColor.red, 0.8)
        XCTAssertLessThan(firstColor.blue, 0.2)

        // 尺寸与标注集合不变，仅移动选区到蓝色区域：缓存必须按新 origin 重采样
        drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 200))
        let blueSelection = CGRect(x: 500, y: 100, width: 200, height: 200)
        XCTAssertEqual(canvas.selection, blueSelection)
        let second = try XCTUnwrap(canvas.committedAnnotationLayer(for: blueSelection, visibleAnnotations: canvas.annotations))
        let secondColor = try XCTUnwrap(PixelSampler(image: second).color(at: samplePoint))
        XCTAssertGreaterThan(secondColor.blue, 0.8)
        XCTAssertLessThan(secondColor.red, 0.2)
    }

    func testAnnotationCachePixelSizeMatchesExportRounding() throws {
        // 分数坐标 + 非整数 scale：缓存位图尺寸必须与导出裁剪的逐边舍入一致
        // scale 1.5 时 round(width*scale)=150 而逐边舍入=151，可区分两种策略
        let image = Self.makeImage(width: 1200, height: 900)
        captured = CapturedScreen(screen: NSScreen.main ?? NSScreen.screens[0], image: image, scale: 1.5)
        canvas = SelectionCanvasView(captured: captured, mode: .edit)
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas

        let selection = CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.5)
        let annotation = Annotation(kind: .rectangle(CGRect(x: 5, y: 5, width: 40, height: 20)), color: .red)
        canvas.configureForSnapshot(
            selection: selection,
            annotations: [annotation],
            tool: .move,
            color: .red,
            lineWidth: 4,
            filled: false,
            withToolbar: false
        )
        let layer = try XCTUnwrap(canvas.committedAnnotationLayer(for: selection, visibleAnnotations: canvas.annotations))
        let expected = Geometry.pixelRect(for: selection, scale: 1.5)
        XCTAssertEqual(layer.width, Int(expected.width))
        XCTAssertEqual(layer.height, Int(expected.height))
        XCTAssertEqual(layer.width, 151)
    }

    // MARK: - Event helpers

    private func drag(from: CGPoint, to: CGPoint) {
        sendMouse(.leftMouseDown, at: from, clickCount: 1)
        sendMouse(.leftMouseDragged, at: to, clickCount: 1)
        sendMouse(.leftMouseUp, at: to, clickCount: 1)
    }

    private func click(at point: CGPoint) {
        sendMouse(.leftMouseDown, at: point, clickCount: 1)
        sendMouse(.leftMouseUp, at: point, clickCount: 1)
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = makeMouseEvent(type, at: point, clickCount: clickCount, modifiers: modifiers) else {
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

    private func drag(view: NSView, from: CGPoint, to: CGPoint) {
        guard let down = makeMouseEvent(.leftMouseDown, at: from, clickCount: 1),
              let moved = makeMouseEvent(.leftMouseDragged, at: to, clickCount: 1),
              let up = makeMouseEvent(.leftMouseUp, at: to, clickCount: 1)
        else {
            XCTFail("Failed to create mouse events")
            return
        }
        view.mouseDown(with: down)
        view.mouseDragged(with: moved)
        view.mouseUp(with: up)
    }

    private func makeMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        let windowPoint = CGPoint(x: point.x, y: (window.contentView?.bounds.height ?? 600) - point.y)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )
    }

    private func sendKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Failed to create key event")
            return
        }
        canvas.keyDown(with: event)
    }

    private func press(_ character: String, keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
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
