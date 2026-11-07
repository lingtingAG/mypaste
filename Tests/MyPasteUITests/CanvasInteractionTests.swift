import AppKit
import XCTest
@testable import MyPasteCore
@testable import MyPasteUI

@MainActor
final class CanvasInteractionTests: XCTestCase {
    private var window: NSWindow!
    private var canvas: SelectionCanvasView!
    private var captured: CapturedScreen!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
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
