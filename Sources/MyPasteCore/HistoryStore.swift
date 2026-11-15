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
    public let thumbnailFileSize: Int64

    public init(
        id: String,
        url: URL,
        thumbnailURL: URL,
        createdAt: Date,
        pixelSize: CGSize?,
        fileSize: Int64,
        thumbnailFileSize: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.fileSize = fileSize
        self.thumbnailFileSize = thumbnailFileSize
    }

    /// 磁盘占用 = 原图 + 缩略图，清理预算按此计算
    public var diskFootprint: Int64 { fileSize + thumbnailFileSize }
}

// 所有文件读写经内部串行队列序列化，可安全跨线程调用
public final class HistoryStore: @unchecked Sendable {
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
    ///   - onError: 记录写入失败回调（主线程），不要静默失败
    ///   - onPruneError: 旧记录清理失败回调（主线程）。本次记录已成功，文案必须与写入失败区分
    /// 异步接口没有同步返回值，结果只经 completion 交付
    public func record(
        _ image: CGImage,
        pngData: Data? = nil,
        limit: Int? = nil,
        diskLimitMB: Int? = nil,
        completion: ((HistoryEntry?) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil,
        onPruneError: ((Error) -> Void)? = nil
    ) {
        let effectiveLimit = limit ?? AppSettings.shared.historyLimit
        let effectiveDiskLimit = diskLimitMB ?? AppSettings.shared.historyDiskLimitMB
        queue.async { [weak self] in
            guard let self else { return }
            var pruneError: Error?
            do {
                // 清理旧条目的 IO 失败不影响本次写入结果，单独作为错误上报
                let entry = try self.recordOnQueue(
                    image,
                    pngData: pngData,
                    limit: effectiveLimit,
                    diskLimitMB: effectiveDiskLimit,
                    onPruneError: { pruneError = $0 }
                )
                DispatchQueue.main.async {
                    completion?(entry)
                    if let pruneError { onPruneError?(pruneError) }
                    NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(nil)
                    onError?(error)
                }
            }
        }
    }

    /// 同步入口，内部仍经串行队列序列化；不可在 store 队列内部调用（会死锁）
    @discardableResult
    public func recordSync(
        _ image: CGImage,
        pngData: Data? = nil,
        limit: Int? = nil,
        diskLimitMB: Int? = nil
    ) throws -> HistoryEntry {
        try queue.sync {
            try recordOnQueue(image, pngData: pngData, limit: limit, diskLimitMB: diskLimitMB)
        }
    }

    private func recordOnQueue(
        _ image: CGImage,
        pngData: Data?,
        limit: Int?,
        diskLimitMB: Int?,
        onPruneError: ((Error) -> Void)? = nil
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

        var thumbnailSize: Int64 = 0
        if let thumb = Self.makeThumbnail(image, maxPixel: 640),
           let thumbData = ImageExporter.pngData(thumb) {
            // 缩略图写入失败不阻断主记录，但预算只统计实际落盘的字节
            do {
                try thumbData.write(to: thumbnailURL, options: .atomic)
                thumbnailSize = Int64(thumbData.count)
            } catch {
                thumbnailSize = 0
            }
        }

        let entry = HistoryEntry(
            id: base,
            url: url,
            thumbnailURL: thumbnailURL,
            createdAt: now,
            pixelSize: CGSize(width: image.width, height: image.height),
            fileSize: Int64(png.count),
            thumbnailFileSize: thumbnailSize
        )
        do {
            try pruneOnQueue(limit: limit ?? AppSettings.shared.historyLimit, diskLimitBytes: diskLimitMB.map { Int64($0) * 1024 * 1024 })
        } catch {
            if let onPruneError {
                onPruneError(error)
            } else {
                throw error
            }
        }
        return entry
    }

    public func entries() -> [HistoryEntry] {
        queue.sync { Self.listEntries(in: rootURL) }
    }

    public static func listEntries(in rootURL: URL) -> [HistoryEntry] {
        Self.diskEntries(in: rootURL).map { item in
            HistoryEntry(
                id: item.url.deletingPathExtension().lastPathComponent,
                url: item.url,
                thumbnailURL: item.thumbnailURL,
                createdAt: item.createdAt,
                pixelSize: Self.pixelSize(of: item.url),
                fileSize: item.fileSize,
                thumbnailFileSize: item.thumbnailFileSize
            )
        }
    }

    /// 轻量磁盘清单：只取文件属性，不解码图像头。
    /// prune 的条数/字节预算只依赖这些属性，记录路径不应为尺寸解码付出 O(N) 成本。
    private struct DiskEntry {
        let url: URL
        let thumbnailURL: URL
        let createdAt: Date
        let fileSize: Int64
        let thumbnailFileSize: Int64
        var footprint: Int64 { fileSize + thumbnailFileSize }
    }

    private static func diskEntries(in rootURL: URL) -> [DiskEntry] {
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
            .compactMap { url -> DiskEntry? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let created = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                let thumb = rootURL.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_thumb.png")
                let thumbValues = try? thumb.resourceValues(forKeys: [.fileSizeKey])
                return DiskEntry(
                    url: url,
                    thumbnailURL: thumb,
                    createdAt: created,
                    fileSize: Int64(values?.fileSize ?? 0),
                    thumbnailFileSize: Int64(thumbValues?.fileSize ?? 0)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ entry: HistoryEntry, onError: ((Error) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            var firstError: Error?
            for url in [entry.url, entry.thumbnailURL] {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // 文件已不存在视为删除成功（缩略图可能从未写成功）
                    if !Self.isMissingFile(error), firstError == nil { firstError = error }
                }
            }
            DispatchQueue.main.async {
                if let firstError { onError?(firstError) }
                NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
            }
        }
    }

    public func clear(onError: ((Error) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            var firstError: Error?
            do {
                let urls = try fm.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: nil)
                for url in urls where url.pathExtension.lowercased() == "png" {
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        if !Self.isMissingFile(error), firstError == nil { firstError = error }
                    }
                }
            } catch {
                if !Self.isMissingFile(error) { firstError = error }
            }
            DispatchQueue.main.async {
                if let firstError { onError?(firstError) }
                NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
            }
        }
    }

    /// 按条数与磁盘字节双重上限清理，从最旧开始删除，至少保留最新一条。
    /// 同步入口，内部经串行队列序列化；不可在 store 队列内部调用。
    public func prune(limit: Int, diskLimitMB: Int? = nil) throws {
        try prune(limit: limit, diskLimitBytes: diskLimitMB.map { Int64($0) * 1024 * 1024 })
    }

    public func prune(limit: Int, diskLimitBytes: Int64?) throws {
        try queue.sync {
            try pruneOnQueue(limit: limit, diskLimitBytes: diskLimitBytes)
        }
    }

    private func pruneOnQueue(limit: Int, diskLimitBytes: Int64?) throws {
        var kept = Self.diskEntries(in: rootURL)
        var total = kept.reduce(Int64(0)) { $0 + $1.footprint }
        var firstError: Error?
        while kept.count > 1,
              kept.count > limit || (diskLimitBytes.map { total > $0 } ?? false) {
            let removed = kept.removeLast()
            // 只有实际删除成功（或文件已不存在）才释放预算；删不掉的文件仍占磁盘
            for (url, size) in [(removed.url, removed.fileSize), (removed.thumbnailURL, removed.thumbnailFileSize)] {
                do {
                    try FileManager.default.removeItem(at: url)
                    total -= size
                } catch {
                    if Self.isMissingFile(error) {
                        total -= size
                    } else if firstError == nil {
                        // 单个文件删除失败不中断整轮清理，收集后继续删下一条
                        firstError = error
                    }
                }
            }
        }
        // 清理没有对应原图的孤儿缩略图（原图已删、缩略图删除失败的残留）
        if let urls = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            for url in urls where url.lastPathComponent.hasSuffix("_thumb.png") {
                let base = String(url.lastPathComponent.dropLast("_thumb.png".count))
                let mainURL = rootURL.appendingPathComponent(base + ".png")
                guard !FileManager.default.fileExists(atPath: mainURL.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    if !Self.isMissingFile(error), firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
    }

    /// 外部调用的清理入口（设置变更时），走内部队列并在完成后发通知
    public func pruneAsync(limit: Int, diskLimitMB: Int? = nil, onError: ((Error) -> Void)? = nil) {
        let disk = diskLimitMB ?? AppSettings.shared.historyDiskLimitMB
        queue.async { [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                try self.pruneOnQueue(limit: limit, diskLimitBytes: Int64(disk) * 1024 * 1024)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                if let failure { onError?(failure) }
                NotificationCenter.default.post(name: .myPasteHistoryDidChange, object: self)
            }
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
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
