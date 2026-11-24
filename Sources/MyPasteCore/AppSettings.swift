import Foundation

public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults: UserDefaults
    private let prefix = "com.mypaste."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            prefix + "playSound": true,
            prefix + "showMagnifier": true,
            prefix + "autoSave": false,
            prefix + "historyLimit": 50,
            prefix + "historyDiskLimitMB": 500,
            prefix + "toolLineWidth": 4.0,
            prefix + "toolFontSize": 20.0,
            prefix + "toolFilled": false,
            prefix + "toolColor": RGBAColor.red.hexString,
            prefix + "saveFormat": SaveFormat.png.rawValue,
            prefix + "jpegQuality": 0.92,
        ])
    }

    public var captureShortcut: Shortcut {
        get { shortcut(forKey: "captureShortcut") ?? .capture }
        set { setShortcut(newValue, forKey: "captureShortcut") }
    }

    public var pinShortcut: Shortcut {
        get { shortcut(forKey: "pinShortcut") ?? .pin }
        set { setShortcut(newValue, forKey: "pinShortcut") }
    }

    public var fullScreenShortcut: Shortcut {
        get { shortcut(forKey: "fullScreenShortcut") ?? .fullScreen }
        set { setShortcut(newValue, forKey: "fullScreenShortcut") }
    }

    public var playSound: Bool {
        get { defaults.bool(forKey: prefix + "playSound") }
        set { set(newValue, key: "playSound") }
    }

    public var showMagnifier: Bool {
        get { defaults.bool(forKey: prefix + "showMagnifier") }
        set { set(newValue, key: "showMagnifier") }
    }

    public var autoSave: Bool {
        get { defaults.bool(forKey: prefix + "autoSave") }
        set { set(newValue, key: "autoSave") }
    }

    public var historyLimit: Int {
        get { max(10, defaults.integer(forKey: prefix + "historyLimit")) }
        set { set(max(10, newValue), key: "historyLimit") }
    }

    public var historyDiskLimitMB: Int {
        get { max(100, defaults.integer(forKey: prefix + "historyDiskLimitMB")) }
        set { set(max(100, newValue), key: "historyDiskLimitMB") }
    }

    public var toolLineWidth: CGFloat {
        get {
            let value = defaults.double(forKey: prefix + "toolLineWidth")
            return value > 0 ? CGFloat(value) : 4
        }
        set { set(Double(newValue), key: "toolLineWidth") }
    }

    public var toolFontSize: CGFloat {
        get {
            let value = defaults.double(forKey: prefix + "toolFontSize")
            return value > 0 ? TextMetrics.clampedFontSize(CGFloat(value)) : 20
        }
        set { set(Double(TextMetrics.clampedFontSize(newValue)), key: "toolFontSize") }
    }

    public var toolFilled: Bool {
        get { defaults.bool(forKey: prefix + "toolFilled") }
        set { set(newValue, key: "toolFilled") }
    }

    public var toolColor: RGBAColor {
        get {
            if let raw = defaults.string(forKey: prefix + "toolColor"),
               let color = RGBAColor(hexString: raw) {
                return color
            }
            return .red
        }
        set { set(newValue.hexString, key: "toolColor") }
    }

    public var saveFormat: SaveFormat {
        get {
            guard let raw = defaults.string(forKey: prefix + "saveFormat"),
                  let format = SaveFormat(rawValue: raw) else { return .png }
            return format
        }
        set { set(newValue.rawValue, key: "saveFormat") }
    }

    public var jpegQuality: CGFloat {
        get {
            let value = defaults.double(forKey: prefix + "jpegQuality")
            return value > 0 ? min(1, max(0.1, CGFloat(value))) : 0.92
        }
        set { set(Double(min(1, max(0.1, newValue))), key: "jpegQuality") }
    }

    /// 记住上次选择的标注工具。文字工具与移动工具不作为跨会话初始工具：
    /// 前者会让新会话一点击就弹输入框，后者等价于没有偏好。
    public var lastTool: Tool {
        get {
            guard let raw = defaults.string(forKey: prefix + "lastTool"),
                  let tool = Tool(rawValue: raw),
                  Self.rememberedTools.contains(tool) else { return .move }
            return tool
        }
        set { set(newValue.rawValue, key: "lastTool") }
    }

    private static let rememberedTools: [Tool] = [
        .rectangle, .ellipse, .arrow, .pen, .marker, .mosaic, .blur, .number, .eraser
    ]

    public var saveDirectory: URL {
        get {
            if let raw = defaults.string(forKey: prefix + "saveDirectory"), !raw.isEmpty {
                return URL(fileURLWithPath: raw, isDirectory: true)
            }
            return Self.defaultSaveDirectory
        }
        set {
            set(newValue.path, key: "saveDirectory")
        }
    }

    public static var defaultSaveDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("MyPaste", isDirectory: true)
    }

    public var hasCompletedWelcome: Bool {
        get { defaults.bool(forKey: prefix + "hasCompletedWelcome") }
        set { set(newValue, key: "hasCompletedWelcome") }
    }

    private func shortcut(forKey key: String) -> Shortcut? {
        guard let data = defaults.data(forKey: prefix + key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private func setShortcut(_ shortcut: Shortcut, forKey key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: prefix + key)
        NotificationCenter.default.post(name: .myPasteSettingsDidChange, object: self)
    }

    private func set<T>(_ value: T, key: String) {
        defaults.set(value, forKey: prefix + key)
        NotificationCenter.default.post(name: .myPasteSettingsDidChange, object: self)
    }
}
