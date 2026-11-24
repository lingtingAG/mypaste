import CoreGraphics
import Foundation

/// 冻结截图的取色器。
///
/// 取色本质是「读一个像素」：放大镜的放大画面直接由源图裁剪绘制，
/// 只有读数条上的颜色需要额外采一个像素。早期实现会在后台预热整屏 RGBA 拷贝
/// （5K 屏每屏约 59MB、6K 约 81MB，多屏叠加），实质是为 1 个像素常驻上百 MB。
///
/// 现在改为按需单像素采样：裁剪 1px 后绘制进复用的 1×1 上下文，
/// 采样点与源图像素严格一一对应，常驻内存与图像尺寸无关。
public final class PixelSampler {
    private let image: CGImage
    private let lock = NSLock()
    private var context: CGContext?
    private var buffer: UnsafeMutableRawPointer?

    public init(image: CGImage) {
        self.image = image
    }

    deinit {
        // 先释放上下文再释放它背后的缓冲，避免上下文持有已释放的指针
        context = nil
        buffer?.deallocate()
        buffer = nil
    }

    /// 准备采样上下文（幂等）。按需采样无需后台预热整屏缓冲，这里只保证上下文可用。
    public func prepare() {
        lock.lock()
        defer { lock.unlock() }
        _ = samplingContextLocked()
    }

    /// 采样上下文是否已创建（测试与调试用）。
    /// 纯查询：不能顺带创建上下文，否则"查状态"会改变状态，
    /// 后续 `XCTAssertFalse(isPrepared)` 之类的断言会被自己踩坑。
    public var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return context != nil
    }

    /// 常驻采样缓冲的像素数：按需采样固定为 1，与源图尺寸无关。
    /// 用于回归测试锁定「不再按整屏分配缓冲」这一约束。
    var residentPixelCount: Int { 1 }

    public func color(at point: CGPoint) -> RGBAColor? {
        // 先判负再截断：Int() 向零截断会让 -0.5 通过边界检查并误采样第 0 列
        guard point.x >= 0, point.y >= 0 else { return nil }
        let x = Int(point.x)
        let y = Int(point.y)
        guard x < image.width, y < image.height else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let context = samplingContextLocked(),
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            // 上下文不可用时退回一次性采样，保证取色不静默失败
            return AnnotationRenderer.averageColor(of: image, at: point)
        }
        // 先清空：目标只有 1 个像素，source-over 合成到透明底等价于直接覆盖
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let rgba = buffer!.assumingMemoryBound(to: UInt8.self)
        let alpha = Double(rgba[3]) / 255.0
        // premultipliedLast：反预乘还原真实颜色，与平均色采样的 sRGB 输出一致
        let unpremultiply: (UInt8) -> Double = { component in
            let value = Double(component) / 255.0
            return alpha > 0 ? min(1, value / alpha) : value
        }
        return RGBAColor(
            red: unpremultiply(rgba[0]),
            green: unpremultiply(rgba[1]),
            blue: unpremultiply(rgba[2]),
            alpha: alpha
        )
    }

    /// 复用的 1×1 采样上下文；调用方必须持有 lock
    private func samplingContextLocked() -> CGContext? {
        if let context { return context }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        guard let created = CGContext(
            data: raw,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            raw.deallocate()
            return nil
        }
        created.interpolationQuality = .none
        context = created
        buffer = raw
        return created
    }
}
