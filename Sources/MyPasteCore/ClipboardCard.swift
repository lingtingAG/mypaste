import AppKit
import CoreGraphics
import Foundation

public enum OffscreenRenderer {
    /// Renders AppKit drawing into a 2x CGImage using top-left, y-down point coordinates.
    public static func render(size: CGSize, scale: CGFloat = 2, draw: (CGContext) -> Void) -> CGImage? {
        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

public enum ClipboardCard {
    public struct Card {
        public let image: CGImage
        public let displaySize: CGSize

        public init(image: CGImage, displaySize: CGSize) {
            self.image = image
            self.displaySize = displaySize
        }
    }

    public static func make(from rawText: String) -> Card? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count <= 96, let color = parseColor(text) {
            return makeColorCard(color: color, rawText: text)
        }
        return makeTextCard(text)
    }

    public static func makeColorCard(color: RGBAColor, rawText: String) -> Card? {
        let size = CGSize(width: 440, height: 200)
        let image = OffscreenRenderer.render(size: size) { _ in
            let cardRect = NSRect(origin: .zero, size: size)
            NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: cardRect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()

            let swatchRect = NSRect(x: 24, y: 28, width: 144, height: 144)
            color.nsColor.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 10, yRadius: 10).fill()
            NSColor.white.withAlphaComponent(0.2).setStroke()
            let border = NSBezierPath(roundedRect: swatchRect, xRadius: 10, yRadius: 10)
            border.lineWidth = 1
            border.stroke()

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                .kern: 1.2,
            ]
            ("COLOR" as NSString).draw(at: NSPoint(x: 192, y: 34), withAttributes: titleAttributes)

            let hexAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            (color.hexString.uppercased() as NSString).draw(at: NSPoint(x: 192, y: 58), withAttributes: hexAttributes)

            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.62),
            ]
            (color.rgbDescription as NSString).draw(at: NSPoint(x: 192, y: 106), withAttributes: detailAttributes)
            let alphaText = String(format: "Alpha %.2f", color.alpha)
            (alphaText as NSString).draw(at: NSPoint(x: 192, y: 130), withAttributes: detailAttributes)

            let hintAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.3),
            ]
            ("来自剪贴板" as NSString).draw(at: NSPoint(x: 192, y: 158), withAttributes: hintAttributes)
        }
        guard let image else { return nil }
        return Card(image: image, displaySize: size)
    }

    public static func makeTextCard(_ text: String) -> Card? {
        let maximumCharacters = 8000
        var displayText = text
        if displayText.count > maximumCharacters {
            displayText = String(displayText.prefix(maximumCharacters)) + "…"
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        let font = NSFont.systemFont(ofSize: 15, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: displayText, attributes: attributes)
        let contentMaxWidth: CGFloat = 560
        let measured = attributed.boundingRect(
            with: CGSize(width: contentMaxWidth, height: 1600),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let contentWidth = max(180, min(contentMaxWidth, ceil(measured.width)))
        let contentHeight = max(18, min(1600, ceil(measured.height)))
        let padding = CGSize(width: 22, height: 20)
        let size = CGSize(
            width: max(220, contentWidth + padding.width * 2),
            height: contentHeight + padding.height * 2
        )

        let image = OffscreenRenderer.render(size: size) { _ in
            let cardRect = NSRect(origin: .zero, size: size)
            NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: cardRect.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13).fill()
            NSColor.white.withAlphaComponent(0.1).setStroke()
            let border = NSBezierPath(roundedRect: cardRect.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
            border.lineWidth = 1
            border.stroke()

            let accent = NSRect(x: 0, y: 20, width: 3, height: size.height - 40)
            NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.95, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: accent, xRadius: 1.5, yRadius: 1.5).fill()

            attributed.draw(
                with: NSRect(
                    x: padding.width,
                    y: padding.height,
                    width: contentWidth,
                    height: contentHeight
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
        guard let image else { return nil }
        return Card(image: image, displaySize: size)
    }

    // MARK: - Color parsing

    public static func parseColor(_ raw: String) -> RGBAColor? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        if lower.hasPrefix("#") {
            return RGBAColor(hexString: lower)
        }
        if lower.hasPrefix("0x") {
            return RGBAColor(hexString: String(lower.dropFirst(2)))
        }
        if lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(") {
            return parseRGBFunction(lower)
        }

        switch lower {
        case "red", "红", "红色": return .red
        case "orange", "橙", "橙色": return .orange
        case "yellow", "黄", "黄色": return .yellow
        case "green", "绿", "绿色": return .green
        case "cyan", "青", "青色": return .cyan
        case "blue", "蓝", "蓝色": return .blue
        case "purple", "紫", "紫色": return .purple
        case "magenta", "pink", "粉", "粉色": return .magenta
        case "white", "白", "白色": return .white
        case "black", "黑", "黑色": return .black
        default:
            break
        }

        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if (text.count == 6 || text.count == 8), text.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) {
            let hasLetter = text.rangeOfCharacter(from: CharacterSet.letters) != nil
            if hasLetter {
                return RGBAColor(hexString: text)
            }
        }
        return nil
    }

    private static func parseRGBFunction(_ text: String) -> RGBAColor? {
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"),
              close > open else { return nil }
        let inside = text[text.index(after: open)..<close]
        let parts = inside
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func component(_ value: String) -> Double? {
            if value.hasSuffix("%") {
                guard let number = Double(value.dropLast()) else { return nil }
                return min(max(number / 100, 0), 1)
            }
            guard let number = Double(value) else { return nil }
            return min(max(number / 255, 0), 1)
        }
        guard let r = component(parts[0]), let g = component(parts[1]), let b = component(parts[2]) else { return nil }
        var alpha = 1.0
        if parts.count == 4 {
            if let a = Double(parts[3]) { alpha = min(max(a, 0), 1) }
        }
        return RGBAColor(red: r, green: g, blue: b, alpha: alpha)
    }
}
