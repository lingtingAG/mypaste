import AppKit
import CoreGraphics
import ScreenCaptureKit

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

    public var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func captureAllScreens() async throws -> [CapturedScreen] {
        guard hasPermission else { throw ScreenCaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var captured: [CapturedScreen] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.mpDisplayID else { continue }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

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
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                captured.append(CapturedScreen(screen: screen, image: image, scale: scale))
            } catch {
                throw ScreenCaptureError.captureFailed(error.localizedDescription)
            }
        }

        guard !captured.isEmpty else { throw ScreenCaptureError.noDisplays }
        return captured
    }

    public func captureScreen(under cocoaPoint: CGPoint) async throws -> CapturedScreen {
        let screens = try await captureAllScreens()
        if let match = screens.first(where: { $0.frame.contains(cocoaPoint) }) {
            return match
        }
        guard let first = screens.first else { throw ScreenCaptureError.noDisplays }
        return first
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
