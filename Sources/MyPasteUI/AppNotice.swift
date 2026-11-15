import AppKit

/// 应用级非模态提示条。
///
/// 用于后台类错误提示（如历史记录清理失败）：这类失败会持续发生，用模态 alert
/// 会让用户每次操作都要手动关弹窗。提示条不进入模态循环、不抢焦点，
/// 层级高于截图覆盖窗（.screenSaver），且不吞掉覆盖窗上的鼠标事件。
@MainActor
public enum AppNotice {
    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?
    private static var lastSignature: String?
    private static var lastShownAt = Date.distantPast
    /// 同一内容的最小重复间隔：清理类错误每次截图都会复现，不应反复提示
    private static let repeatInterval: TimeInterval = 60

    public static func show(title: String, detail: String? = nil, duration: TimeInterval = 4.5) {
        let signature = title + "\n" + (detail ?? "")
        let now = Date()
        if lastSignature == signature, now.timeIntervalSince(lastShownAt) < repeatInterval {
            return
        }
        lastSignature = signature
        lastShownAt = now

        dismissWorkItem?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = panel.contentView as? NoticeView
        view?.update(title: title, detail: detail)
        let size = NSSize(
            width: NoticeView.panelWidth,
            height: NoticeView.height(for: title, detail: detail)
        )
        panel.setContentSize(size)
        position(panel, size: size)
        panel.orderFront(nil)

        let work = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: NoticeView.panelWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // 不抢焦点、不拦鼠标：覆盖窗上的拖选与取色必须照常工作
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NoticeView()
        return panel
    }

    private static func position(_ panel: NSPanel, size: NSSize) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 离屏快照用：渲染提示条外观，返回图像与其逻辑尺寸。
    /// 离屏视图没有 window backing scale，必须显式按 scale 建位图，否则默认 1x 被放大后发糊。
    public static func snapshot(title: String, detail: String?, scale: CGFloat = 2) -> (image: CGImage, size: CGSize)? {
        let size = CGSize(width: NoticeView.panelWidth, height: NoticeView.height(for: title, detail: detail))
        let view = NoticeView(frame: NSRect(origin: .zero, size: size))
        view.update(title: title, detail: detail)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(size.width * scale))),
            pixelsHigh: max(1, Int(ceil(size.height * scale))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        return (image, size)
    }
}

private final class NoticeView: NSView {
    static let panelWidth: CGFloat = 380
    private static let paddingX: CGFloat = 20
    private static let paddingY: CGFloat = 14
    private static let detailLineHeight: CGFloat = 16
    private static let maxDetailLines = 2
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    /// 正文左内边距：让开左侧的警示色条
    private static let textInsetLeft: CGFloat = 26
    /// 测量与绘制必须用同一个宽度，否则截断后的省略号会被挤到下一行裁掉
    private static var textWidth: CGFloat { panelWidth - textInsetLeft - paddingX }

    private var titleText = ""
    private var detailText: String?

    override var isFlipped: Bool { true }

    func update(title: String, detail: String?) {
        titleText = title
        detailText = detail.map { Self.truncate($0) }
        needsDisplay = true
    }

    static func height(for title: String, detail: String?) -> CGFloat {
        let lines = detail.map { detailLineCount($0) } ?? 0
        return paddingY * 2 + titleFont.pointSize + 4 + CGFloat(lines) * detailLineHeight
    }

    private static func detailLineCount(_ detail: String) -> Int {
        min(max(rawLineCount(detail), 1), maxDetailLines)
    }

    private static func rawLineCount(_ detail: String) -> Int {
        let rect = (detail as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: detailFont],
            context: nil
        )
        return max(1, Int(ceil(rect.height / detailLineHeight)))
    }

    /// 超过两行的详情截断并补省略号，避免直接切一半看起来像渲染出错
    private static func truncate(_ detail: String) -> String {
        guard rawLineCount(detail) > maxDetailLines else { return detail }
        var low = 0
        var high = detail.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(detail.prefix(mid)) + "…"
            if rawLineCount(candidate) <= maxDetailLines {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(detail.prefix(low)) + "…"
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.13, alpha: 0.96).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        NSColor.systemOrange.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 12, y: 12, width: 3, height: max(0, bounds.height - 24)),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()

        let textX = Self.textInsetLeft
        let textWidth = max(0, bounds.width - textX - Self.paddingX)
        (titleText as NSString).draw(
            at: CGPoint(x: textX, y: Self.paddingY),
            withAttributes: [
                .font: Self.titleFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
        )
        if let detailText, !detailText.isEmpty {
            (detailText as NSString).draw(
                with: NSRect(
                    x: textX,
                    y: Self.paddingY + Self.titleFont.pointSize + 4,
                    width: textWidth,
                    height: Self.detailLineHeight * CGFloat(Self.maxDetailLines)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: Self.detailFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                ]
            )
        }
    }
}
