import Foundation

/// 截图文件包含完整屏幕像素：落盘后只允许当前用户读写。
/// 收紧失败必须向上抛并进入调用方的错误提示流程，不能静默留下 0644 文件；
/// 写盘时若收紧失败则删掉刚写的文件，避免留下权限不符的屏幕内容。
public enum SecureFileWriter {
    private static let privateFilePermissions = NSNumber(value: 0o600)
    private static let privateDirectoryPermissions = NSNumber(value: 0o700)

    /// 内部可替换点：测试注入失败以验证收紧失败不会被吞掉。
    /// 串行测试里替换并还原；生产始终使用 FileManager.setAttributes。
    static var attributeSetter: (String, [FileAttributeKey: Any]) throws -> Void = { path, attributes in
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }

    private static func apply(_ permissions: NSNumber, at url: URL) throws {
        try attributeSetter(url.path, [.posixPermissions: permissions])
    }

    /// 只保证父目录存在；新建时用 0700，不改动用户通过 NSOpenPanel 选择的已有目录权限。
    public static func ensureDirectory(at url: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        // withIntermediateDirectories 创建的中间目录不保证继承 attributes，最终目录必须收紧成功
        try apply(privateDirectoryPermissions, at: url)
    }

    /// 应用自有目录（历史库）：即使已存在也收紧到 0700，兼容旧版本以 0755 创建的目录。
    public static func ensurePrivateDirectory(at url: URL) throws {
        try ensureDirectory(at: url)
        try apply(privateDirectoryPermissions, at: url)
    }

    /// 非 write() 路径创建的文件（APFS 克隆 / 硬链接）统一收紧到 0600
    public static func normalizeFilePermissions(at url: URL) throws {
        try apply(privateFilePermissions, at: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(at: url.deletingLastPathComponent())
        // .atomic 先写临时文件再替换，不会留下半张截图；替换后立即收紧最终文件
        try data.write(to: url, options: .atomic)
        do {
            try apply(privateFilePermissions, at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
