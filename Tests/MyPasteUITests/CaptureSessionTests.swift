import AppKit
import XCTest
@testable import MyPasteUI

@MainActor
final class CaptureSessionTests: XCTestCase {
    /// 会话结束必须立刻通知宿主释放引用：
    /// 写盘等异步收尾可能滞后于会话结束，宿主不释放引用会让后续截图被"会话存在"拦下
    func testCloseNotifiesHostToReleaseSession() {
        var closedCount = 0
        let session = CaptureSession(
            capturedScreens: [],
            mode: .edit,
            callbacks: CaptureSession.Callbacks(
                onCopy: { _ in },
                onPin: { _ in },
                onSaved: { _, _ in },
                onSaveFailed: { _ in },
                onCancel: {},
                onColorPicked: { _ in },
                onClosed: { closedCount += 1 }
            )
        )

        session.cancel()
        XCTAssertEqual(closedCount, 1)

        // 重复结束不应重复通知
        session.cancel()
        XCTAssertEqual(closedCount, 1)
    }
}
