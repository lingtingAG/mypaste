import AppKit
import XCTest
@testable import MyPasteUI

@MainActor
final class AppNoticeTests: XCTestCase {
    /// 离屏快照必须按 2x 渲染：1x 位图被 2x 画布放大后文字会发糊
    func testSnapshotRendersAt2xLogicalSize() throws {
        _ = NSApplication.shared
        let shot = try XCTUnwrap(AppNotice.snapshot(
            title: "历史记录清理失败",
            detail: "截图已保存，但清理旧历史记录失败：The file couldn’t be removed."
        ))
        XCTAssertEqual(shot.image.width, Int(ceil(shot.size.width * 2)))
        XCTAssertEqual(shot.image.height, Int(ceil(shot.size.height * 2)))
    }
}
