import AppKit
import XCTest
@testable import MyPasteCore
@testable import MyPasteUI

private enum TestCaptureError: Error { case boom }

/// 可延迟完成的抓屏替身：复现「超时 / 取消之后旧任务才返回」。
private final class DelayedCaptureService: ScreenCaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingAll: CheckedContinuation<ScreenCaptureBatch, Error>?
    private var pendingOne: CheckedContinuation<CapturedScreen, Error>?
    private var starts = 0
    private var onStart: (() -> Void)?
    private let screen: NSScreen
    private let image: CGImage

    init(screen: NSScreen, image: CGImage) {
        self.screen = screen
        self.image = image
    }

    var hasPermission: Bool { true }
    func requestPermission() -> Bool { true }

    func setStartHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        onStart = handler
        lock.unlock()
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func captureAllScreens() async throws -> ScreenCaptureBatch {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingAll = continuation
            starts += 1
            let handler = onStart
            lock.unlock()
            handler?()
        }
    }

    func captureScreen(under cocoaPoint: CGPoint) async throws -> CapturedScreen {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingOne = continuation
            starts += 1
            let handler = onStart
            lock.unlock()
            handler?()
        }
    }

    func resumeAllScreens() {
        lock.lock()
        let continuation = pendingAll
        pendingAll = nil
        lock.unlock()
        continuation?.resume(returning: ScreenCaptureBatch(
            screens: [CapturedScreen(screen: screen, image: image, scale: 2)],
            unmappedScreenCount: 0
        ))
    }

    func resumeScreen() {
        lock.lock()
        let continuation = pendingOne
        pendingOne = nil
        lock.unlock()
        continuation?.resume(returning: CapturedScreen(screen: screen, image: image, scale: 2))
    }

    func failAllScreens() {
        lock.lock()
        let continuation = pendingAll
        pendingAll = nil
        lock.unlock()
        continuation?.resume(throwing: TestCaptureError.boom)
    }
}

@MainActor
final class CaptureRaceTests: XCTestCase {
    private static let suiteName = "com.mypaste.tests.race"
    private var roots: [URL] = []
    private var pasteboard: NSPasteboard?
    private var defaults: UserDefaults?

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        pasteboard?.releaseGlobally()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        pasteboard = nil
        defaults = nil
        super.tearDown()
    }

    /// 取消后旧任务才返回：不得写剪贴板、归档或自动保存，也不得弹错误窗。
    func testCancelledFullScreenResultProducesNoSideEffects() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let service = DelayedCaptureService(screen: screen, image: try makeImage())
        let (environment, historyRoot, saveDirectory) = try makeEnvironment(service: service)
        let controller = CaptureController(environment: environment)
        let board = environment.pasteboard
        let changeCount = board.changeCount

        let started = expectation(description: "capture started")
        service.setStartHandler { started.fulfill() }
        controller.captureFullScreen()
        wait(for: [started], timeout: 2)
        XCTAssertEqual(service.startCount, 1)

        controller.cancelActiveSession()
        service.resumeScreen()
        // 让旧任务的 continuation 恢复、work 返回与 defer 执行完毕
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(board.changeCount, changeCount, "取消后旧任务不得写剪贴板")
        XCTAssertFalse(controller.isSessionActive)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: historyRoot.path).isEmpty,
            "取消后旧任务不得写入历史库"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: saveDirectory.path),
            "取消后旧任务不得自动保存"
        )
    }

    /// 超时后旧任务才返回：不得创建会话，且状态必须已复位、后续截图可重入。
    func testTimedOutRegionResultDoesNotCreateSessionOrBlockState() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let service = DelayedCaptureService(screen: screen, image: try makeImage())
        let (environment, _, _) = try makeEnvironment(service: service, timeout: 60_000_000)
        let controller = CaptureController(environment: environment)

        let started = expectation(description: "first capture started")
        service.setStartHandler { started.fulfill() }
        controller.captureRegion()
        wait(for: [started], timeout: 2)

        // 60ms 守护触发；RunLoop 让 MainActor 上的守护 Task 得以恢复
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        service.resumeAllScreens()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertFalse(controller.isSessionActive, "超时后旧任务不得创建覆盖窗会话")
        XCTAssertEqual(service.startCount, 1)

        // 关键回归：旧任务若把状态留在 .presenting，第二次截图会被 guard 静默丢弃
        let second = expectation(description: "second capture started")
        service.setStartHandler { second.fulfill() }
        controller.captureRegion()
        wait(for: [second], timeout: 2)
        XCTAssertEqual(service.startCount, 2, "状态不能卡在 .presenting")

        controller.cancelActiveSession()
        service.resumeAllScreens()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// 旧任务抛错时也不得进入错误处理（否则会弹模态框）；用短超时后失败返回覆盖。
    func testStaleCaptureFailureDoesNotPresentError() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let service = DelayedCaptureService(screen: screen, image: try makeImage())
        let (environment, _, _) = try makeEnvironment(service: service)
        let controller = CaptureController(environment: environment)

        let started = expectation(description: "capture started")
        service.setStartHandler { started.fulfill() }
        controller.captureRegion()
        wait(for: [started], timeout: 2)

        controller.cancelActiveSession()
        service.failAllScreens()
        // 未加守卫时 handleCaptureError 的 runModal 会在此卡住并使测试超时失败
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(controller.isSessionActive)
    }

    private func makeEnvironment(
        service: ScreenCaptureProviding,
        timeout: UInt64 = 10_000_000_000
    ) throws -> (CaptureEnvironment, URL, URL) {
        let fm = FileManager.default
        let historyRoot = fm.temporaryDirectory
            .appendingPathComponent("MyPasteRaceHistory-\(UUID().uuidString)", isDirectory: true)
        let saveDirectory = fm.temporaryDirectory
            .appendingPathComponent("MyPasteRaceSave-\(UUID().uuidString)", isDirectory: true)
        roots.append(contentsOf: [historyRoot, saveDirectory])

        let board = NSPasteboard(name: NSPasteboard.Name("MyPasteRace-\(UUID().uuidString)"))
        pasteboard = board
        let prefs = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        prefs.removePersistentDomain(forName: Self.suiteName)
        defaults = prefs
        let settings = AppSettings(defaults: prefs)
        settings.autoSave = true
        settings.playSound = false
        settings.saveDirectory = saveDirectory

        let environment = CaptureEnvironment(
            service: service,
            pasteboard: board,
            historyStore: HistoryStore(rootURL: historyRoot),
            settings: settings,
            timeoutNanoseconds: timeout
        )
        return (environment, historyRoot, saveDirectory)
    }

    private func makeImage(width: Int = 24, height: Int = 16) throws -> CGImage {
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
