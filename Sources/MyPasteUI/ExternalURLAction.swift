import Foundation

/// `mypaste://` 的动作分类。URL scheme 是进程间入口，任何本地进程都能触发；
/// 不产生可见界面却会读写剪贴板 / 落盘 / 终止应用的动作必须先经用户确认，
/// 否则无屏幕录制权限的进程可以借已授权的 MyPaste 静默代抓整屏。
///
/// 未采用 `keySenderPIDAttr` 校验：URL scheme 的发送者一律是 LaunchServices / `open`，
/// 无法据此区分用户手动执行与恶意进程调用，确认框 + 最小权限才是有效边界。
public enum ExternalURLAction: Equatable, Sendable {
    case capture
    case colorPicker
    case history
    case settings
    case pin
    case fullScreen
    case quit
    case unknown

    public init(host: String?) {
        switch host?.lowercased() {
        case "capture": self = .capture
        case "colorpicker", "picker": self = .colorPicker
        case "history": self = .history
        case "settings", "preferences": self = .settings
        case "pin": self = .pin
        case "fullscreen": self = .fullScreen
        case "quit": self = .quit
        default: self = .unknown
        }
    }

    /// 会写剪贴板 / 落盘 / 终止应用且没有覆盖层可见的动作
    public var requiresConfirmation: Bool {
        switch self {
        case .pin, .fullScreen, .quit: return true
        case .capture, .colorPicker, .history, .settings, .unknown: return false
        }
    }

    public var confirmationTitle: String {
        switch self {
        case .pin: return "允许贴图剪贴板？"
        case .fullScreen: return "允许截取整个屏幕？"
        case .quit: return "允许退出 MyPaste？"
        default: return "允许该操作？"
        }
    }

    public var confirmationDetail: String {
        switch self {
        case .pin:
            return "该请求来自外部应用。允许后会读取系统剪贴板内容并生成置顶贴图。"
        case .fullScreen:
            return "该请求来自外部应用。允许后会截取当前屏幕并写入系统剪贴板；本次不会自动保存到文件夹。"
        case .quit:
            return "该请求来自外部应用。允许后会立即退出，未保存的内容将丢失。"
        default:
            return "该请求来自外部应用。"
        }
    }
}
