import AppKit
import CoreGraphics
import Foundation

public enum Tool: String, CaseIterable, Sendable {
    case move
    case rectangle
    case ellipse
    case arrow
    case pen
    case marker
    case text
    case mosaic
    case blur
    case number
    case eraser

    public var title: String {
        switch self {
        case .move: return "移动选区"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .marker: return "荧光笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .blur: return "高斯模糊"
        case .number: return "序号"
        case .eraser: return "橡皮擦"
        }
    }
}

public enum AnnotationKind: Equatable, Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case pen(points: [CGPoint])
    case marker(points: [CGPoint])
    case text(origin: CGPoint, string: String, fontSize: CGFloat)
    case mosaic(CGRect)
    case blur(CGRect)
    case number(center: CGPoint, value: Int)

    public var tool: Tool {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .pen: return .pen
        case .marker: return .marker
        case .text: return .text
        case .mosaic: return .mosaic
        case .blur: return .blur
        case .number: return .number
        }
    }
}

public enum TextMetrics {
    public static let padding = CGSize(width: 6, height: 4)
    public static let minFontSize: CGFloat = 10
    public static let maxFontSize: CGFloat = 120

    public static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maxFontSize, max(minFontSize, size))
    }

    public static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: max(8, size), weight: .medium)
    }

    public static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        guard !string.isEmpty else { return CGSize(width: 1, height: fontSize) }
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size: fontSize)]
        let measured = (string as NSString).size(withAttributes: attributes)
        return CGSize(width: ceil(measured.width), height: ceil(max(measured.height, fontSize)))
    }

    public static func textRect(origin: CGPoint, string: String, fontSize: CGFloat) -> CGRect {
        let size = textSize(string, fontSize: fontSize)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )
    }
}

public struct Annotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: AnnotationKind
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var filled: Bool

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        color: RGBAColor = .red,
        lineWidth: CGFloat = 4,
        filled: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.filled = filled
    }

    public var bounds: CGRect {
        let pad = lineWidth + 4
        switch kind {
        case let .rectangle(rect), let .ellipse(rect):
            return rect.insetBy(dx: -pad, dy: -pad)
        case let .arrow(from, to):
            return CGRect(
                x: min(from.x, to.x),
                y: min(from.y, to.y),
                width: abs(to.x - from.x),
                height: abs(to.y - from.y)
            ).insetBy(dx: -pad, dy: -pad)
        case let .pen(points), let .marker(points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -pad, dy: -pad)
        case let .text(origin, string, fontSize):
            return TextMetrics.textRect(origin: origin, string: string, fontSize: fontSize)
                .insetBy(dx: -2, dy: -2)
        case let .mosaic(rect), let .blur(rect):
            return rect.insetBy(dx: -pad, dy: -pad)
        case let .number(center, _):
            let radius = Annotation.numberRadius(lineWidth: lineWidth)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        switch kind {
        case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect), let .blur(rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .arrow(from, to):
            return Geometry.distance(from: point, toSegment: from, to) <= max(6, lineWidth + tolerance)
        case let .pen(points):
            return Geometry.distance(from: point, toPolyline: points) <= max(6, lineWidth / 2 + tolerance)
        case let .marker(points):
            return Geometry.distance(from: point, toPolyline: points) <= max(8, lineWidth * 2 + tolerance)
        case let .text(origin, string, fontSize):
            return TextMetrics.textRect(origin: origin, string: string, fontSize: fontSize)
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(point)
        case let .number(center, _):
            let radius = Annotation.numberRadius(lineWidth: lineWidth)
            return hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
        }
    }

    public static func numberRadius(lineWidth: CGFloat) -> CGFloat {
        max(11, 7 + lineWidth * 2.1)
    }
}
