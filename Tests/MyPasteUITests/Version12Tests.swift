import AppKit
import XCTest
@testable import MyPasteCore
@testable import MyPasteUI

/// v1.2 性能与存储优化的回归测试。
@MainActor
final class Version12Tests: XCTestCase {
    private var originalMagnifier = true
    private var originalPinLimit = 20

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        originalMagnifier = AppSettings.shared.showMagnifier
        originalPinLimit = AppSettings.shared.pinLimit
    }

    override func tearDown() {
        AppSettings.shared.showMagnifier = originalMagnifier
        AppSettings.shared.pinLimit = originalPinLimit
        super.tearDown()
    }

    func testPixelSamplingDoesNotAllocateFullScreenBuffer() throws {
        AppSettings.shared.showMagnifier = false
        let edit = SelectionCanvasView(captured: try makeCaptured(), mode: .edit)
        AppSettings.shared.showMagnifier = true
        let picker = SelectionCanvasView(captured: try makeCaptured(), mode: .colorPicker)
        // v1.3：取色改为按需单像素采样，常驻缓冲与源图尺寸无关，
        // 放大镜开关不再决定是否分配整屏 RGBA 拷贝
        XCTAssertEqual(edit.pixelSampler.residentPixelCount, 1)
        XCTAssertEqual(picker.pixelSampler.residentPixelCount, 1)
    }

    func testCursorDirtyRectsCoverBothCursorsAndStaySmall() throws {
        AppSettings.shared.showMagnifier = true
        let canvas = SelectionCanvasView(captured: try makeCaptured())
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let old = CGPoint(x: 100, y: 100)
        let new = CGPoint(x: 300, y: 200)
        let rects = canvas.cursorDirtyRects(old: old, new: new)

        XCTAssertFalse(rects.isEmpty)
        // 十字线横贯全屏，旧 / 新光标都必须落在脏区内，否则会留下残影
        XCTAssertTrue(rects.contains { $0.contains(old) })
        XCTAssertTrue(rects.contains { $0.contains(new) })
        let total = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertLessThan(total, canvas.bounds.width * canvas.bounds.height * 0.3)
    }

    func testPinBoardEvictsOldestAtLimit() throws {
        AppSettings.shared.pinLimit = 5
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let board = PinBoard()
        defer { board.closeAll() }
        let image = try makeImage()
        for _ in 0..<7 {
            board.present(image: image, at: nil, screen: screen, scale: 2)
        }
        XCTAssertEqual(board.count, 5)
    }

    func testInteractiveResizeDefersHighQualityRedraw() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let board = PinBoard()
        defer { board.closeAll() }
        let pin = board.present(image: try makeImage(), at: nil, screen: screen, scale: 2)
        let view = try XCTUnwrap(pin.window?.contentView)
        XCTAssertEqual(view.layerContentsRedrawPolicy, .duringViewResize)
        let originalFrame = try XCTUnwrap(pin.window?.frame)
        let scaled = CGRect(
            origin: originalFrame.origin,
            size: CGSize(width: originalFrame.width * 1.2, height: originalFrame.height * 1.2)
        )
        pin.resizeInteractively(to: scaled)
        XCTAssertEqual(pin.window?.frame.size.width ?? 0, scaled.width, accuracy: 0.5)
        XCTAssertTrue(pin.isInteractivelyResizing, "连续缩放期间应跳过高质量整图重绘")
        // 默认 .duringViewResize 会在 resize 后的下一 runloop 标脏重绘，必须显式关掉
        XCTAssertEqual(view.layerContentsRedrawPolicy, .never)

        let settled = expectation(description: "防抖后恢复高质量重绘")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(pin.isInteractivelyResizing)
            XCTAssertEqual(view.layerContentsRedrawPolicy, .duringViewResize)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
    }

    private func makeCaptured() throws -> CapturedScreen {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        return CapturedScreen(screen: screen, image: try makeImage(), scale: 2)
    }

    private func makeImage(width: Int = 40, height: Int = 30) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
