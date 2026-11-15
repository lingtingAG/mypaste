import AppKit
import CoreGraphics

public enum ImageComposer {
    public static func outputPixelSize(selectionRect: CGRect, scale: CGFloat) -> CGSize {
        let rect = Geometry.pixelRect(for: selectionRect, scale: scale)
        return CGSize(width: max(1, rect.width), height: max(1, rect.height))
    }

    public static func compose(
        baseImage: CGImage,
        selectionRect: CGRect,
        screenScale: CGFloat,
        annotations: [Annotation]
    ) -> CGImage? {
        guard screenScale > 0, selectionRect.width >= 1, selectionRect.height >= 1 else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let pixelRect = Geometry.pixelRect(for: selectionRect, scale: screenScale)
            .integral
            .intersection(imageBounds)
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        guard let cropped = baseImage.cropping(to: pixelRect) else { return nil }
        if annotations.isEmpty { return cropped }

        let width = Int(pixelRect.width)
        let height = Int(pixelRect.height)
        let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: screenScale, y: screenScale)

        // 底图按像素矩形对应的点尺寸从原点绘制：selectionRect.size * scale 可能比 pixelRect 少 1px，
        // 按点尺寸绘制会在右/下边缘留半透明缝（与无标注路径、预览不一致）；
        // 裁剪图对应选区原点，必须落在 (0,0) 而不是 pixelRect.origin 对应的偏移处
        let canvasRect = CGRect(
            origin: .zero,
            size: Geometry.pointRect(for: pixelRect, scale: screenScale).size
        )
        AnnotationRenderer.drawImageTopLeft(cropped, in: canvasRect, in: context)
        let source = RenderSource(image: cropped, originInImage: .zero, pixelsPerPoint: screenScale)
        AnnotationRenderer.draw(
            annotations: annotations,
            in: context,
            selectionSize: selectionRect.size,
            source: source
        )
        return context.makeImage()
    }

    public static func crop(_ image: CGImage, selectionRect: CGRect, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = Geometry.pixelRect(for: selectionRect, scale: scale).integral.intersection(bounds)
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
