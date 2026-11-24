import AppKit
import XCTest
@testable import MyPasteCore
@testable import MyPasteUI

/// v1.1 新增行为的回归测试：外部 URL 策略、成功提示去重、多屏失败聚合、工具跨会话记忆。
@MainActor
final class Version11Tests: XCTestCase {
    func testExternalURLActionsRequireConfirmationOnlyForSensitiveHosts() {
        XCTAssertEqual(ExternalURLAction(host: "capture"), .capture)
        XCTAssertEqual(ExternalURLAction(host: "PICKER"), .colorPicker)
        XCTAssertEqual(ExternalURLAction(host: "preferences"), .settings)
        XCTAssertEqual(ExternalURLAction(host: "history"), .history)
        XCTAssertEqual(ExternalURLAction(host: "fullscreen"), .fullScreen)
        XCTAssertEqual(ExternalURLAction(host: "pin"), .pin)
        XCTAssertEqual(ExternalURLAction(host: "quit"), .quit)
        XCTAssertEqual(ExternalURLAction(host: nil), .unknown)
        XCTAssertEqual(ExternalURLAction(host: "unknown-action"), .unknown)

        for host in ["capture", "picker", "history", "settings"] {
            XCTAssertFalse(ExternalURLAction(host: host).requiresConfirmation)
        }
        for host in ["pin", "fullscreen", "quit"] {
            let action = ExternalURLAction(host: host)
            XCTAssertTrue(action.requiresConfirmation)
            XCTAssertFalse(action.confirmationTitle.isEmpty)
            XCTAssertFalse(action.confirmationDetail.isEmpty)
        }
        XCTAssertFalse(ExternalURLAction.unknown.requiresConfirmation)
    }

    func testAppNoticeDedupeCanBeDisabledForSuccessMessages() {
        let now = Date()
        let signature = "已复制到剪贴板\n"
        XCTAssertTrue(AppNotice.shouldSuppress(
            signature: signature,
            now: now.addingTimeInterval(1),
            lastSignature: signature,
            lastShownAt: now,
            dedupe: true
        ))
        XCTAssertFalse(AppNotice.shouldSuppress(
            signature: signature,
            now: now.addingTimeInterval(1),
            lastSignature: signature,
            lastShownAt: now,
            dedupe: false
        ))
        // 60 秒后同文案的错误也应重新提示
        XCTAssertFalse(AppNotice.shouldSuppress(
            signature: signature,
            now: now.addingTimeInterval(61),
            lastSignature: signature,
            lastShownAt: now,
            dedupe: true
        ))
        XCTAssertFalse(AppNotice.shouldSuppress(
            signature: "另一条错误\n",
            now: now.addingTimeInterval(1),
            lastSignature: signature,
            lastShownAt: now,
            dedupe: true
        ))
    }

    func testScreenCaptureBatchAggregatesIncompleteScreens() {
        let partial = ScreenCaptureBatch(screens: [], unmappedScreenCount: 1, failedCaptureCount: 2)
        XCTAssertEqual(partial.incompleteScreenCount, 3)
        XCTAssertEqual(partial.failedCaptureCount, 2)
        let complete = ScreenCaptureBatch(screens: [], unmappedScreenCount: 0)
        XCTAssertEqual(complete.failedCaptureCount, 0)
        XCTAssertEqual(complete.incompleteScreenCount, 0)
    }

    func testCanvasRestoresRememberedToolAcrossSessions() throws {
        _ = NSApplication.shared
        let original = AppSettings.shared.lastTool
        defer { AppSettings.shared.lastTool = original }
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let captured = CapturedScreen(screen: screen, image: try makeImage(), scale: 2)

        AppSettings.shared.lastTool = .rectangle
        let first = SelectionCanvasView(captured: captured)
        XCTAssertEqual(first.tool, .rectangle)
        first.selectAll(nil)
        // 建立选区后不能把记住的工具冲掉，否则跨会话记忆形同虚设
        XCTAssertEqual(first.tool, .rectangle)

        first.toolbar(EditorToolbarView(), perform: .selectTool(.pen))
        XCTAssertEqual(AppSettings.shared.lastTool, .pen)
        XCTAssertEqual(SelectionCanvasView(captured: captured).tool, .pen)
    }

    func testCanvasDefaultsToMoveToolWhenNoPreference() throws {
        _ = NSApplication.shared
        let original = AppSettings.shared.lastTool
        defer { AppSettings.shared.lastTool = original }
        AppSettings.shared.lastTool = .move
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let canvas = SelectionCanvasView(
            captured: CapturedScreen(screen: screen, image: try makeImage(), scale: 2)
        )
        XCTAssertEqual(canvas.tool, .move)
        canvas.selectAll(nil)
        XCTAssertEqual(canvas.tool, .move)
    }

    func testCancelActiveSessionIsSafeWithoutSession() {
        let controller = CaptureController()
        XCTAssertFalse(controller.isSessionActive)
        controller.cancelActiveSession()
        XCTAssertFalse(controller.isSessionActive)
    }

    func testPreferencesExposesJPEGQualityControlLinkedToFormat() throws {
        _ = NSApplication.shared
        let suite = "com.mypaste.tests.preferences"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.saveFormat = .jpeg
        settings.jpegQuality = 0.75
        let controller = PreferencesWindowController(settings: settings, onHotkeysChanged: { [] })
        guard let view = controller.makeSnapshotContentView() else {
            return XCTFail("设置窗口内容视图不可用")
        }
        // 质量档位 tag 为百分数，其他弹出菜单（历史张数 / MB / 格式）不含 75
        let qualityPopup = try XCTUnwrap(
            Self.popupButtons(in: view).first { $0.itemArray.contains { $0.tag == 75 } }
        )
        XCTAssertEqual(qualityPopup.selectedTag(), 75)
        XCTAssertTrue(qualityPopup.isEnabled)

        settings.saveFormat = .png
        _ = controller.makeSnapshotContentView()
        XCTAssertFalse(qualityPopup.isEnabled, "非 JPEG 格式时质量控制应禁用")
    }

    private static func popupButtons(in view: NSView) -> [NSPopUpButton] {
        var result: [NSPopUpButton] = []
        for subview in view.subviews {
            if let popup = subview as? NSPopUpButton { result.append(popup) }
            result.append(contentsOf: popupButtons(in: subview))
        }
        return result
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
