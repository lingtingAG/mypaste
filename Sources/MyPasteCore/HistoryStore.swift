import AppKit
import CoreGraphics
import Foundation
import ImageIO

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let thumbnailURL: URL
    public let createdAt: Date
    public let pixelSize: CGSize?
    public let fileSize: Int64

    public init(
        id: String,
        url: URL,
        thumbnailURL: URL,
        createdAt: Date,
        pixelSize: CGSize?,
        fileSize: Int64
    ) {
        self.id = id
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.fileSize = fileSize
    }
}

public final class HistoryStore {
    public static let shared = HistoryStore()

    public let rootURL: URL
    // 所有文件读写都走同一串行队列，避免 record 与 delete/clear 竞争
    private let queue = DispatchQueue(label: "com.mypaste.history", qos: .utility)

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.rootURL = support.appendingPathComponent("MyPaste/History", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    /// - Parameters:
    ///   - pngData: 调用方已编码的 PNG，传入可复用编码结果；为 nil 时内部编码
    ///   - onError: 写入失败回调（主线程），不要静默失败
    @discardableResult
    public func record(
        _ image: CGImage,
        pngData: Data? = nil,
        completion: ((HistoryEntry?) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> HistoryEntry? {
        let limit = AppSettings.shared.historyLimit
        let diskLimit = AppSettings.shared.historyDiskLimitMB
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let entry = try self.recordSync(image, pngData: pngData, limit: limit, diskLimitMB: diskLimit)
                DispatchQueue.main.async {
                    completion?(entry)
                    NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(nil)
                    onError?(error)
                }
            }
        }
        return nil
    }

    @discardableResult
    public func recordSync(
        _ image: CGImage,
        pngData: Data? = nil,
        limit: Int? = nil,
        diskLimitMB: Int? = nil
    ) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let now = Date()
        let unique = UUID().uuidString.prefix(4)
        let base = "\(ImageExporter.timestampBase(date: now))_\(unique)"
        let url = rootURL.appendingPathComponent(base + ".png")
        let thumbnailURL = rootURL.appendingPathComponent(base + "_thumb.png")

        guard let png = pngData ?? ImageExporter.pngData(image) else {
            throw ImageExporter.ExportError.encodingFailed
        }
        try png.write(to: url, options: .atomic)

        if let thumb = Self.makeThumbnail(image, maxPixel: 640),
           let thumbData = ImageExporter.pngData(thumb) {
            try? thumbData.write(to: thumbnailURL, options: .atomic)
        }

        let entry = HistoryEntry(
            id: base,
            url: url,
            thumbnailURL: thumbnailURL,
            createdAt: now,
            pixelSize: CGSize(width: image.width, height: image.height),
            fileSize: Int64(png.count)
        )
        try prune(limit: limit ?? AppSettings.shared.historyLimit, diskLimitMB: diskLimitMB)
        return entry
    }

    public func entries() -> [HistoryEntry] {
        queue.sync { Self.listEntries(in: rootURL) }
    }

    public static func listEntries(in rootURL: URL) -> [HistoryEntry] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return url.pathExtension.lowercased() == "png" && !name.hasSuffix("_thumb.png")
            }
            .compactMap { url -> HistoryEntry? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let created = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                let thumb = rootURL.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_thumb.png")
                return HistoryEntry(
                    id: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    thumbnailURL: thumb,
                    createdAt: created,
                    pixelSize: Self.pixelSize(of: url),
                    fileSize: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ entry: HistoryEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: entry.thumbnailURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
            }
        }
    }

    public func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            if let urls = try? fm.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: nil) {
                for url in urls where url.pathExtension.lowercased() == "png" {
                    try? fm.removeItem(at: url)
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
            }
        }
    }

    /// 按条数与磁盘字节双重上限清理，从最旧开始删除，至少保留最新一条
    public func prune(limit: Int, diskLimitMB: Int? = nil) throws {
        try prune(limit: limit, diskLimitBytes: diskLimitMB.map { Int64($0) * 1024 * 1024 })
    }

    public func prune(limit: Int, diskLimitBytes: Int64?) throws {
        var kept = Self.listEntries(in: rootURL)
        var total = kept.reduce(Int64(0)) { $0 + $1.fileSize }
        while kept.count > 1,
              kept.count > limit || (diskLimitBytes.map { total > $0 } ?? false) {
            let removed = kept.removeLast()
            total -= removed.fileSize
            try? FileManager.default.removeItem(at: removed.url)
            try? FileManager.default.removeItem(at: removed.thumbnailURL)
        }
    }

    /// 外部调用的清理入口（设置变更时），走内部队列并在完成后发通知
    public func pruneAsync(limit: Int, diskLimitMB: Int? = nil) {
        let disk = diskLimitMB ?? AppSettings.shared.historyDiskLimitMB
        queue.async { [weak self] in
            guard let self else { return }
            try? self.prune(limit: limit, diskLimitMB: disk)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
            }
        }
    }

    public static func makeThumbnail(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxPixel / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
