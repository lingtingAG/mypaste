import Darwin
import Foundation

/// PNG 自动保存与历史原图内容逐字节相同：复用已落盘的数据，省掉第二次写盘与双倍空间。
///
/// 优先 APFS `clonefile`（写时复制、独立 inode，用户日后在 Finder 原地编辑自动保存文件
/// 不会串改历史原图）；不支持时退硬链接；跨卷 / 记录已被 prune 删除 / 权限收紧失败
/// 一律退回普通写，绝不静默丢失自动保存。
public enum SpaceSavingWriter {
    /// `source == nil`（历史写入失败）或源已被 prune 删除时退回普通写，
    /// 保持「自动保存与历史库两条路径互相独立」的旧语义。
    public static func copy(from source: URL?, to destination: URL, fallbackData: Data) throws {
        let fm = FileManager.default
        try SecureFileWriter.ensureDirectory(at: destination.deletingLastPathComponent())
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        guard let source, fm.fileExists(atPath: source.path), isRegularFile(source) else {
            try SecureFileWriter.write(fallbackData, to: destination)
            return
        }

        if cloneFile(from: source, to: destination) {
            do {
                try SecureFileWriter.normalizeFilePermissions(at: destination)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            return
        }

        do {
            try fm.linkItem(at: source, to: destination)
            try SecureFileWriter.normalizeFilePermissions(at: destination)
        } catch {
            // linkItem 跨卷会失败；权限收紧失败也不留下 0644 的屏幕内容
            try? fm.removeItem(at: destination)
            try SecureFileWriter.write(fallbackData, to: destination)
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func cloneFile(from source: URL, to destination: URL) -> Bool {
        source.path.withCString { src in
            destination.path.withCString { dst in
                clonefile(src, dst, 0) == 0
            }
        }
    }
}
