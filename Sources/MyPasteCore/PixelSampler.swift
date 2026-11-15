import CoreGraphics
import Foundation

/// 冻结截图的像素缓冲采样器。缓冲就绪后取色为 O(1) 内存读取；
/// 缓冲在后台构建，构建期间用 1px 裁剪采样降级，
/// 避免首次放大镜绘制在主线程分配并渲染整屏图像（6K 屏约 80MB）。
public final class PixelSampler {
    private let image: CGImage
    private let lock = NSLock()
    private var buffer: [UInt8]?
    private var bytesPerRow = 0
    private var isBuilding = false
    // 渲染失败后不再重试：prepare() 会被每个鼠标事件调用，反复后台渲染整屏代价过高
    private var didFail = false

    public init(image: CGImage) {
        self.image = image
    }

    /// 触发后台构建（幂等）。画布取色前调用即可，不阻塞主线程。
    public func prepare() {
        lock.lock()
        let shouldBuild = buffer == nil && !isBuilding && !didFail
        if shouldBuild { isBuilding = true }
        lock.unlock()
        guard shouldBuild else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let rendered = Self.renderBuffer(for: self.image)
            self.lock.lock()
            if let rendered {
                self.buffer = rendered.data
                self.bytesPerRow = rendered.bytesPerRow
            } else {
                self.didFail = true
            }
            self.isBuilding = false
            self.lock.unlock()
        }
    }

    public func color(at point: CGPoint) -> RGBAColor? {
        // 先判负再截断：Int() 向零截断会让 -0.5 通过边界检查并误采样第 0 列
        guard point.x >= 0, point.y >= 0 else { return nil }
        let x = Int(point.x)
        let y = Int(point.y)
        guard x < image.width, y < image.height else { return nil }
        lock.lock()
        let buffer = self.buffer
        let bytesPerRow = self.bytesPerRow
        lock.unlock()
        guard let buffer else {
            // 缓冲尚未就绪：单像素裁剪采样，成本与旧 averageColor 一致
            return AnnotationRenderer.averageColor(of: image, at: point)
        }
        let offset = y * bytesPerRow + x * 4
        guard offset + 3 < buffer.count else { return nil }
        let alpha = Double(buffer[offset + 3]) / 255.0
        // premultipliedLast：反预乘还原真实颜色，与平均色采样的 sRGB 输出一致
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

    private static func renderBuffer(for image: CGImage) -> (data: [UInt8], bytesPerRow: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
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
        guard built else { return nil }
        return (data, rowBytes)
    }
}
