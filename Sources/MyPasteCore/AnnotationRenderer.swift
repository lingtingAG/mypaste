import AppKit
import CoreGraphics
import CoreImage
import CoreText

public struct RenderSource {
    public let image: CGImage
    public let originInImage: CGPoint
    public let pixelsPerPoint: CGFloat

    public init(image: CGImage, originInImage: CGPoint = .zero, pixelsPerPoint: CGFloat = 2) {
        self.image = image
        self.originInImage = originInImage
        self.pixelsPerPoint = max(0.01, pixelsPerPoint)
    }
}

public enum AnnotationRenderer {
    private static let ciContext = CIContext()

    /// Draws annotations into a context whose current coordinate system is top-left
    /// origin, y-down, and measured in points. The caller is responsible for the
    /// selection clip and for positioning origin at (0, 0).
    public static func draw(
        annotations: [Annotation],
        in context: CGContext,
        selectionSize: CGSize,
        source: RenderSource?
    ) {
        guard !annotations.isEmpty else { return }
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: selectionSize))
        for annotation in annotations {
            draw(annotation: annotation, in: context, source: source)
        }
        context.restoreGState()
    }

    public static func draw(annotation: Annotation, in context: CGContext, source: RenderSource?) {
        let color = annotation.color
        context.setStrokeColor(color.nsColor.cgColor)
        context.setFillColor(color.nsColor.cgColor)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case let .rectangle(rect):
            let path = CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(path)
            if annotation.filled {
                context.fillPath()
            } else {
                context.strokePath()
            }

        case let .ellipse(rect):
            if annotation.filled {
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
            } else {
                context.strokeEllipse(in: rect)
            }

        case let .arrow(from, to):
            drawArrow(from: from, to: to, lineWidth: annotation.lineWidth, color: color, in: context)

        case let .pen(points):
            drawSmoothStroke(points, lineWidth: annotation.lineWidth, color: color, in: context)

        case let .marker(points):
            drawSmoothStroke(
                points,
                lineWidth: max(8, annotation.lineWidth * 3.6),
                color: color.withAlpha(0.32),
                in: context
            )

        case let .text(origin, string, fontSize):
            drawText(string, origin: origin, fontSize: fontSize, color: color, in: context)

        case let .mosaic(rect):
            drawMosaic(rect, lineWidth: annotation.lineWidth, source: source, in: context)

        case let .blur(rect):
            drawBlur(rect, lineWidth: annotation.lineWidth, source: source, in: context)

        case let .number(center, value):
            drawNumber(value, center: center, lineWidth: annotation.lineWidth, color: color, in: context)
        }
    }

    public static func drawImageTopLeft(_ image: CGImage, in rect: CGRect, in context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: - Primitives

    private static func drawSmoothStroke(_ points: [CGPoint], lineWidth: CGFloat, color: RGBAColor, in context: CGContext) {
        guard let first = points.first else { return }
        context.setStrokeColor(color.nsColor.cgColor)
        context.setFillColor(color.nsColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if points.count == 1 {
            let radius = lineWidth / 2
            context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            return
        }

        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for index in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[index].x + points[index + 1].x) / 2,
                    y: (points[index].y + points[index + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[index])
            }
            path.addQuadCurve(to: points[points.count - 1], control: points[points.count - 2])
        }
        context.addPath(path)
        context.strokePath()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, color: RGBAColor, in context: CGContext) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        context.setStrokeColor(color.nsColor.cgColor)
        context.setFillColor(color.nsColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        guard length > 1 else {
            let radius = max(2, lineWidth / 2)
            context.fillEllipse(in: CGRect(x: from.x - radius, y: from.y - radius, width: radius * 2, height: radius * 2))
            return
        }

        let angle = atan2(dy, dx)
        let headLength = min(max(11, lineWidth * 4.2), length)
        let halfWidth = headLength * 0.46
        let baseCenter = CGPoint(x: to.x - cos(angle) * headLength, y: to.y - sin(angle) * headLength)
        let left = CGPoint(
            x: baseCenter.x + cos(angle + .pi / 2) * halfWidth,
            y: baseCenter.y + sin(angle + .pi / 2) * halfWidth
        )
        let right = CGPoint(
            x: baseCenter.x + cos(angle - .pi / 2) * halfWidth,
            y: baseCenter.y + sin(angle - .pi / 2) * halfWidth
        )

        context.move(to: from)
        context.addLine(to: baseCenter)
        context.strokePath()

        let head = CGMutablePath()
        head.move(to: to)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        context.addPath(head)
        context.fillPath()
    }

    private static func drawText(_ string: String, origin: CGPoint, fontSize: CGFloat, color: RGBAColor, in context: CGContext) {
        guard !string.isEmpty else { return }
        let rect = TextMetrics.textRect(origin: origin, string: string, fontSize: fontSize)
        let font = TextMetrics.font(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.nsColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let baseline = rect.minY + TextMetrics.padding.height + font.ascender
        drawTextLine(line, x: rect.minX + TextMetrics.padding.width, baselineY: baseline, in: context)
    }

    private static func drawNumber(_ value: Int, center: CGPoint, lineWidth: CGFloat, color: RGBAColor, in context: CGContext) {
        let radius = Annotation.numberRadius(lineWidth: lineWidth)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(color.nsColor.cgColor)
        context.fillEllipse(in: circleRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(max(1, lineWidth * 0.35))
        context.strokeEllipse(in: circleRect)

        let fontSize = max(11, radius * 1.05)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(value)", attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        drawTextLine(
            line,
            x: center.x - width / 2,
            baselineY: center.y + (ascent - descent) / 2,
            in: context
        )
    }

    private static func drawTextLine(_ line: CTLine, x: CGFloat, baselineY: CGFloat, in context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: x, y: baselineY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Effects

    private static func drawMosaic(_ rect: CGRect, lineWidth: CGFloat, source: RenderSource?, in context: CGContext) {
        guard let source, rect.width >= 1, rect.height >= 1 else { return }
        let scale = source.pixelsPerPoint
        let pixelRect = CGRect(
            x: source.originInImage.x + rect.minX * scale,
            y: source.originInImage.y + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        let clipped = pixelRect.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        guard let crop = source.image.cropping(to: clipped) else { return }

        let blockPixels = max(3, Int((max(4, lineWidth * 1.2) * scale).rounded()))
        let smallWidth = max(1, Int(clipped.width) / blockPixels)
        let smallHeight = max(1, Int(clipped.height) / blockPixels)
        let colorSpace = source.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let smallContext = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        smallContext.interpolationQuality = .low
        smallContext.draw(crop, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let smallImage = smallContext.makeImage() else { return }

        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .none
        drawImageTopLeft(smallImage, in: rect, in: context)
        context.restoreGState()
    }

    private static func drawBlur(_ rect: CGRect, lineWidth: CGFloat, source: RenderSource?, in context: CGContext) {
        guard let source, rect.width >= 1, rect.height >= 1 else { return }
        let scale = source.pixelsPerPoint
        let padPoints = max(8, lineWidth * 5)
        let expanded = rect.insetBy(dx: -padPoints, dy: -padPoints)
        let pixelRect = CGRect(
            x: source.originInImage.x + expanded.minX * scale,
            y: source.originInImage.y + expanded.minY * scale,
            width: expanded.width * scale,
            height: expanded.height * scale
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        let clipped = pixelRect.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return }
        guard let crop = source.image.cropping(to: clipped) else { return }

        let ciImage = CIImage(cgImage: crop).clampedToExtent()
        let radius = max(4, lineWidth * 2 * scale)
        guard let output = ciImage
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)) as CIImage?,
            let blurred = ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        else { return }

        let clippedLocal = Geometry.pointRect(for: clipped, scale: scale)
            .offsetBy(dx: -source.originInImage.x / scale, dy: -source.originInImage.y / scale)
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .high
        drawImageTopLeft(blurred, in: clippedLocal, in: context)
        context.restoreGState()
    }

    public static func averageColor(of image: CGImage, at point: CGPoint) -> RGBAColor? {
        let x = Int(point.x)
        let y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return RGBAColor(
            red: Double(pixel[0]) / 255.0,
            green: Double(pixel[1]) / 255.0,
            blue: Double(pixel[2]) / 255.0,
            alpha: Double(pixel[3]) / 255.0
        )
    }
}
