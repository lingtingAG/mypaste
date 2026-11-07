import CoreGraphics
import Foundation

/// 冻结截图的像素缓冲采样器。首次采样时把图像渲染为固定 RGBA8 布局，
/// 之后取色为 O(1) 内存读取，避免放大镜每个鼠标事件都走整图绘制。
public final class PixelSampler {
    private let image: CGImage
    private var buffer: [UInt8]?
    private var bytesPerRow = 0

    public init(image: CGImage) {
        self.image = image
    }

    public func color(at point: CGPoint) -> RGBAColor? {
        let x = Int(point.x)
        let y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        if buffer == nil { buildBuffer() }
        guard let buffer else { return nil }
        let offset = y * bytesPerRow + x * 4
        guard offset + 3 < buffer.count else { return nil }
        let alpha = Double(buffer[offset + 3]) / 255.0
        // premultipliedLast：反预乘还原真实颜色，与旧 averageColor 的 sRGB 输出一致
        let unpremultiply: (UInt8) -> Double = { component in
            let value = Double(component) / 255.0
            return alpha > 0 ? min(1, value / alpha) : value
        }
        return RGBAColor(
            red: unpremultiply(buffer[offset]),
            green: unpremultiply(buffer[offset + 1]),
            blue: unpremultiply(buffer[offset + 2]),
            alpha: alpha
        )
    }

    private func buildBuffer() {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return }
        let rowBytes = width * 4
        var data = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let built = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            // CGContext.draw 写入的缓冲行序与 CGImage dataProvider 一致（row 0 = 图像顶部），
            // 无需翻转，采样坐标即可直接使用 top-left/y-down 像素坐标
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard built else { return }
        bytesPerRow = rowBytes
        buffer = data
    }
}