import AppKit
import Combine
import CoreGraphics
import Foundation

public enum ImageExporter {
    public enum ExportError: LocalizedError {
        case encodingFailed
        case unsupportedType

        public var errorDescription: String? {
            switch self {
            case .encodingFailed: return "图片编码失败"
            case .unsupportedType: return "不支持的图片格式"
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

    public static func data(for image: CGImage, fileExtension: String) -> Data? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return jpegData(image)
        case "tif", "tiff":
            return tiffData(image)
        default:
            return pngData(image)
        }
    }

    public static func write(_ image: CGImage, to url: URL) throws {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        guard let data = data(for: image, fileExtension: ext) else {
            throw ExportError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public static func timestampedFileName(date: Date = Date(), fileExtension: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "MyPaste_\(formatter.string(from: date)).\(fileExtension)"
    }

    public static func displayFileName(date: Date = Date(), fileExtension: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "MyPaste \(formatter.string(from: date)).\(fileExtension)"
    }
}

public enum PasteboardWriter {
    public static func writeImage(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = ImageExporter.pngData(image) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = ImageExporter.tiffData(image) {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    public static func writeText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

public enum ClipboardContent {
    case image(CGImage, logicalSize: CGSize?)
    case text(String)
}

public enum PasteboardReader {
    public static func read() -> ClipboardContent? {
        let pasteboard = NSPasteboard.general
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
