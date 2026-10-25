import AppKit
import CoreGraphics
import Foundation
import ImageIO

public struct HistoryEntry: Identifiable, Hashable {
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
    public static let didChangeNotification = Notification.Name("com.mypaste.historyDidChange")

    public let rootURL: URL
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

    @discardableResult
    public func record(_ image: CGImage, completion: ((HistoryEntry?) -> Void)? = nil) -> HistoryEntry? {
        let limit = AppSettings.shared.historyLimit
        queue.async { [weak self] in
            guard let self else { return }
            let entry = try? self.recordSync(image, limit: limit)
            DispatchQueue.main.async {
                completion?(entry)
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
        return nil
    }

    @discardableResult
    public func recordSync(_ image: CGImage, limit: Int? = nil) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let unique = UUID().uuidString.prefix(4)
        let base = "MyPaste_\(formatter.string(from: now))_\(unique)"
        let url = rootURL.appendingPathComponent(base + ".png")
        let thumbnailURL = rootURL.appendingPathComponent(base + "_thumb.png")

        guard let png = ImageExporter.pngData(image) else {
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
        try prune(limit: limit ?? AppSettings.shared.historyLimit)
        return entry
    }

    public func entries() -> [HistoryEntry] {
        Self.listEntries(in: rootURL)
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
        try? FileManager.default.removeItem(at: entry.url)
        try? FileManager.default.removeItem(at: entry.thumbnailURL)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func clear() {
        let fm = FileManager.default
        if let urls = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension.lowercased() == "png" {
                try? fm.removeItem(at: url)
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func prune(limit: Int) throws {
        let all = Self.listEntries(in: rootURL)
        guard all.count > limit else { return }
        for entry in all.dropFirst(limit) {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: entry.thumbnailURL)
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
