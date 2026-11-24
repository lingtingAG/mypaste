import AppKit
import Combine
import CoreGraphics
import Foundation

/// 自动保存与保存面板的默认格式。历史库始终存 PNG（无损、可复用编码结果），不受此设置影响。
public enum SaveFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case tiff

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .png: return "PNG（无损）"
        case .jpeg: return "JPEG（体积更小）"
        case .tiff: return "TIFF"
        }
    }
}

public enum ImageExporter {
    public enum ExportError: LocalizedError {
        case encodingFailed
        case unsupportedType
        case decodeFailed

        public var errorDescription: String? {
            switch self {
            case .encodingFailed: return "图片编码失败"
            case .unsupportedType: return "不支持的图片格式"
            case .decodeFailed: return "图片读取失败"
            }
        }
    }

    public static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    public static func jpegData(_ image: CGImage, quality: CGFloat = 0.92) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    public static func tiffData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:])
    }

    public static func data(for image: CGImage, fileExtension: String, jpegQuality: CGFloat = 0.92) -> Data? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return jpegData(image, quality: jpegQuality)
        case "tif", "tiff":
            return tiffData(image)
        case "png":
            return pngData(image)
        default:
            return nil
        }
    }

    private static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff"]

    public static func write(_ image: CGImage, to url: URL, jpegQuality: CGFloat = 0.92) throws {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        // 扩展名与编码格式必须一致，未知格式显式报错而不是写出内容不符的文件
        guard supportedExtensions.contains(ext) else {
            throw ExportError.unsupportedType
        }
        guard let data = data(for: image, fileExtension: ext, jpegQuality: jpegQuality) else {
            throw ExportError.encodingFailed
        }
        try SecureFileWriter.write(data, to: url)
    }

    // DateFormatter 创建开销高且非线程安全，静态复用并加锁
    private static let formatterLock = NSLock()
    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter
    }()
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    public static func timestampBase(date: Date = Date()) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return "MyPaste_\(fileFormatter.string(from: date))"
    }

    public static func timestampedFileName(date: Date = Date(), fileExtension: String = "png") -> String {
        "\(timestampBase(date: date)).\(fileExtension)"
    }

    public static func displayFileName(date: Date = Date(), fileExtension: String = "png") -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return "MyPaste \(displayFormatter.string(from: date)).\(fileExtension)"
    }
}

public enum PasteboardWriter {
    public static func writeImage(_ image: CGImage, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        // 惰性提供数据：复制时不阻塞主线程编码，读取方按需触发
        item.setDataProvider(LazyImageDataProvider(image: image), forTypes: [.png, .tiff])
        pasteboard.writeObjects([item])
    }

    public static func writeText(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private final class LazyImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let image: CGImage
    private var png: Data?
    private var tiff: Data?

    init(image: CGImage) {
        self.image = image
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .png {
            if png == nil { png = ImageExporter.pngData(image) }
            if let png { item.setData(png, forType: .png) }
        } else if type == .tiff {
            if tiff == nil { tiff = ImageExporter.tiffData(image) }
            if let tiff { item.setData(tiff, forType: .tiff) }
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        png = nil
        tiff = nil
    }
}

public enum ClipboardContent {
    case image(CGImage, logicalSize: CGSize?)
    case text(String)
}

public enum PasteboardReader {
    public static func read(from pasteboard: NSPasteboard = .general) -> ClipboardContent? {
        var logicalSize: CGSize?
        if let image = readImage(from: pasteboard, logicalSize: &logicalSize) {
            return .image(image, logicalSize: logicalSize)
        }
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(string)
        }
        return nil
    }

    private static func readImage(from pasteboard: NSPasteboard, logicalSize: inout CGSize?) -> CGImage? {
        if let image = NSImage(pasteboard: pasteboard) {
            logicalSize = image.size
            var rect = CGRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cgImage
            }
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type),
               let rep = NSBitmapImageRep(data: data),
               let image = rep.cgImage {
                return image
            }
        }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: ["public.image"]]
        ) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    logicalSize = image.size
                }
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    return image
                }
            }
        }
        return nil
    }
}
