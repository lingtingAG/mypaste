import AppKit
import MyPasteCore

/// `CaptureController` 的外部依赖注入点。生产环境用默认值；
/// 测试注入可延迟完成的抓屏替身、独立剪贴板与临时历史库，
/// 才能验证超时 / 取消后旧任务不会继续产生副作用。
public struct CaptureEnvironment {
    public var service: ScreenCaptureProviding
    public var pasteboard: NSPasteboard
    public var historyStore: HistoryStore
    public var settings: AppSettings
    public var timeoutNanoseconds: UInt64

    public init(
        service: ScreenCaptureProviding = ScreenCaptureService(),
        pasteboard: NSPasteboard = .general,
        historyStore: HistoryStore = .shared,
        settings: AppSettings = .shared,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.service = service
        self.pasteboard = pasteboard
        self.historyStore = historyStore
        self.settings = settings
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}
