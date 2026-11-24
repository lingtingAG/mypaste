import AppKit
import CoreGraphics
import ScreenCaptureKit

public struct ScreenCaptureBatch {
    public let screens: [CapturedScreen]
    /// 未能匹配到 SCDisplay 的屏幕数；大于 0 时调用方必须提示用户覆盖不完整
    public let unmappedScreenCount: Int
    /// 匹配成功但抓图失败的屏幕数，与映射失败合并提示
    public let failedCaptureCount: Int

    public var incompleteScreenCount: Int { unmappedScreenCount + failedCaptureCount }

    public init(screens: [CapturedScreen], unmappedScreenCount: Int, failedCaptureCount: Int = 0) {
        self.screens = screens
        self.unmappedScreenCount = unmappedScreenCount
        self.failedCaptureCount = failedCaptureCount
    }
}

/// 抓屏依赖的可注入接口：让控制器能在测试中替换为可延迟完成的替身，
/// 覆盖「超时 / 取消后旧任务才返回」的竞态。
public protocol ScreenCaptureProviding: AnyObject {
    var hasPermission: Bool { get }
    func requestPermission() -> Bool
    func captureAllScreens() async throws -> ScreenCaptureBatch
    func captureScreen(under cocoaPoint: CGPoint) async throws -> CapturedScreen
}

extension ScreenCaptureService: ScreenCaptureProviding {}

public struct CapturedScreen {
    public let screen: NSScreen
    public let image: CGImage
    public let scale: CGFloat

    public init(screen: NSScreen, image: CGImage, scale: CGFloat) {
        self.screen = screen
        self.image = image
        self.scale = scale
    }

    public var frame: CGRect { screen.frame }

    /// HiDPI 缩放分辨率下 backingScaleFactor 可能与实际截图像素不符，
    /// 用图像实际宽度反推 points→pixels 比例
    public static func effectiveScale(imageWidth: Int, frameWidth: CGFloat, fallback: CGFloat) -> CGFloat {
        guard frameWidth > 0, imageWidth > 0 else { return max(0.01, fallback) }
        return max(0.01, CGFloat(imageWidth) / frameWidth)
    }
}

public enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case displayNotFound
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有屏幕录制权限"
        case .noDisplays:
            return "没有找到可截取的显示器"
        case .displayNotFound:
            return "无法匹配当前显示器，请重新启动 MyPaste 后再试"
        case .captureFailed(let message):
            return "截屏失败：\(message)"
        }
    }
}

public final class ScreenCaptureService {
    public static let shared = ScreenCaptureService()

    // CaptureEnvironment 的 public 默认参数需要可见的无参构造
    public init() {}

    public var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func captureAllScreens() async throws -> ScreenCaptureBatch {
        guard hasPermission else { throw ScreenCaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screens = NSScreen.screens
        var unmapped = 0
        // 单屏抓图失败不应作废其他屏已冻结的画面：子任务各自返回 Result，最后按屏幕顺序聚合
        let (images, failures) = await withTaskGroup(
            of: (Int, Result<CapturedScreen, Error>).self
        ) { group in
            for (index, screen) in screens.enumerated() {
                guard let displayID = screen.mpDisplayID,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    unmapped += 1
                    continue
                }
                group.addTask {
                    do {
                        let image = try await Self.captureImage(display: display, screen: screen)
                        let scale = CapturedScreen.effectiveScale(
                            imageWidth: image.width,
                            frameWidth: screen.frame.width,
                            fallback: screen.backingScaleFactor
                        )
                        return (index, .success(CapturedScreen(screen: screen, image: image, scale: scale)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var captured = [Int: CapturedScreen]()
            var failed = 0
            for await (index, result) in group {
                switch result {
                case let .success(screen): captured[index] = screen
                case .failure: failed += 1
                }
            }
            return (captured, failed)
        }

        let result = screens.indices.compactMap { images[$0] }
        // 映射失败与抓图失败分开归类，但都不再静默：全部失败必须抛错
        guard !result.isEmpty else {
            if unmapped > 0 { throw ScreenCaptureError.displayNotFound }
            if failures > 0 { throw ScreenCaptureError.captureFailed("所有显示器均抓取失败") }
            throw ScreenCaptureError.noDisplays
        }
        return ScreenCaptureBatch(
            screens: result,
            unmappedScreenCount: unmapped,
            failedCaptureCount: failures
        )
    }

    /// 只抓目标点所在的屏幕，用于全屏截图等单屏场景，避免抓全部显示器
    public func captureScreen(under cocoaPoint: CGPoint) async throws -> CapturedScreen {
        guard hasPermission else { throw ScreenCaptureError.permissionDenied }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
            ?? NSScreen.main ?? NSScreen.screens.first else {
            throw ScreenCaptureError.noDisplays
        }
        guard let displayID = screen.mpDisplayID else { throw ScreenCaptureError.displayNotFound }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }
        let image = try await Self.captureImage(display: display, screen: screen)
        let scale = CapturedScreen.effectiveScale(
            imageWidth: image.width,
            frameWidth: screen.frame.width,
            fallback: screen.backingScaleFactor
        )
        return CapturedScreen(screen: screen, image: image, scale: scale)
    }

    private static func captureImage(display: SCDisplay, screen: NSScreen) async throws -> CGImage {
        let scale = screen.backingScaleFactor
        let pixelWidth = max(1, Int((screen.frame.width * scale).rounded()))
        let pixelHeight = max(1, Int((screen.frame.height * scale).rounded()))

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}

extension NSScreen {
    var mpDisplayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        if let id = deviceDescription[key] as? CGDirectDisplayID {
            return id
        }
        return nil
    }
}

public enum ScreenPermission {
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
