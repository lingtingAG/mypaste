import AppKit
import CoreGraphics

public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    public init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        if value.count == 8 {
            guard let raw = UInt32(value, radix: 16) else { return nil }
            let rgb = raw >> 8
            let a = Double(raw & 0xFF) / 255.0
            self.init(hex: rgb, alpha: a)
            return
        }
        guard value.count == 6, let raw = UInt32(value, radix: 16) else { return nil }
        self.init(hex: raw)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        nsColor.cgColor
    }

    public var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public var rgbDescription: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return "RGB(\(r), \(g), \(b))"
    }

    public func withAlpha(_ value: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: value)
    }

    public static let red = RGBAColor(hex: 0xF03E3E)
    public static let orange = RGBAColor(hex: 0xFF9500)
    public static let yellow = RGBAColor(hex: 0xFFD60A)
    public static let green = RGBAColor(hex: 0x30D158)
    public static let cyan = RGBAColor(hex: 0x32ADE6)
    public static let blue = RGBAColor(hex: 0x0A84FF)
    public static let purple = RGBAColor(hex: 0xBF5AF2)
    public static let magenta = RGBAColor(hex: 0xFF375F)
    public static let white = RGBAColor(hex: 0xFFFFFF)
    public static let black = RGBAColor(hex: 0x111111)

    public static let palette: [RGBAColor] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .magenta, .white, .black,
    ]
}
