import AppKit
import CoreGraphics
import ImageIO
import MyPasteCore
import UniformTypeIdentifiers

private final class HistoryCardView: NSView {
    let entry: HistoryEntry
    let index: Int
    var isSelectedState = false {
        didSet { needsDisplay = true }
    }
    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?
    var thumbnail: NSImage? {
        didSet { needsDisplay = true }
    }
    private let dateText: String
    private let detailText: String

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    init(entry: HistoryEntry, index: Int, thumbnail: NSImage?) {
        self.entry = entry
        self.index = index
        self.thumbnail = thumbnail
        self.dateText = Self.dateFormatter.string(from: entry.createdAt)
        if let size = entry.pixelSize {
            self.detailText = "\(Int(size.width)) × \(Int(size.height))"
        } else {
            self.detailText = ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file)
        }
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onActivate?(index)
        } else {
            onSelect?(index)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let backgroundRect = bounds.insetBy(dx: 1, dy: 1)
        let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8)
        if isSelectedState {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else if isHovering {
            NSColor.controlBackgroundColor.blended(withFraction: 0.06, of: .labelColor)?.setFill()
                ?? NSColor.controlBackgroundColor.setFill()
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        }
        background.fill()

        let imageRect = CGRect(x: 7, y: 7, width: bounds.width - 14, height: bounds.height - 48)
        let imagePath = NSBezierPath(roundedRect: imageRect, xRadius: 5, yRadius: 5)
        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        imagePath.fill()
        if let thumbnail {
            NSGraphicsContext.saveGraphicsState()
            imagePath.addClip()
            let fitted = Self.aspectFitRect(imageSize: thumbnail.size, in: imageRect.insetBy(dx: 1, dy: 1))
            thumbnail.draw(
                in: fitted,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            symbol?.isTemplate = true
            NSColor.white.withAlphaComponent(0.2).set()
            let side: CGFloat = 26
            symbol?.draw(
                in: CGRect(x: imageRect.midX - side / 2, y: imageRect.midY - side / 2, width: side, height: side)
            )
        }

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let imageBorder = NSBezierPath(roundedRect: imageRect, xRadius: 5, yRadius: 5)
        imageBorder.lineWidth = 1
        imageBorder.stroke()

        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        (dateText as NSString).draw(at: CGPoint(x: 8, y: bounds.height - 36), withAttributes: dateAttributes)

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let detailSize = (detailText as NSString).size(withAttributes: detailAttributes)
        (detailText as NSString).draw(
            at: CGPoint(x: bounds.width - detailSize.width - 8, y: bounds.height - 35),
            withAttributes: detailAttributes
        )

        let border = NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8)
        border.lineWidth = isSelectedState ? 2 : 1
        (isSelectedState ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.55)).setStroke()
        border.stroke()
    }

    private static func aspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private final class HistoryGridView: NSView {
    var cards: [HistoryCardView] = []
    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    func rebuild(entries: [HistoryEntry], thumbnailProvider: (HistoryEntry) -> NSImage?) {
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        for (index, entry) in entries.enumerated() {
            let card = HistoryCardView(entry: entry, index: index, thumbnail: thumbnailProvider(entry))
            card.onSelect = { [weak self] index in self?.onSelect?(index) }
            card.onActivate = { [weak self] index in self?.onActivate?(index) }
            addSubview(card)
            cards.append(card)
        }
        needsLayout = true
    }

    func setSelectedIndex(_ index: Int?) {
        for (cardIndex, card) in cards.enumerated() {
            card.isSelectedState = cardIndex == index
        }
    }

    func layoutCards(width: CGFloat, cardSize: CGSize, gap: CGFloat, inset: CGFloat) -> CGFloat {
        guard !cards.isEmpty else { return 0 }
        let available = max(cardSize.width, width - inset * 2)
        let columns = max(1, Int((available + gap) / (cardSize.width + gap)))
        for (index, card) in cards.enumerated() {
            let column = index % columns
            let row = index / columns
            card.frame = CGRect(
                x: inset + CGFloat(column) * (cardSize.width + gap),
                y: inset + CGFloat(row) * (cardSize.height + gap),
                width: cardSize.width,
                height: cardSize.height
            )
        }
        let rows = (cards.count + columns - 1) / columns
        return inset * 2 + CGFloat(rows) * cardSize.height + CGFloat(max(0, rows - 1)) * gap
    }

    override func layout() {
        super.layout()
        _ = layoutCards(width: bounds.width, cardSize: CGSize(width: 210, height: 176), gap: 14, inset: 18)
    }
}

private final class HistoryBrowserRootView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class HistoryWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

@MainActor
public final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let store: HistoryStore
    private let pinBoard: PinBoard
    private var window: HistoryWindow?
    private var rootView: HistoryBrowserRootView?
    private var scrollView: NSScrollView?
    private var gridView: HistoryGridView?
    private var emptyLabel: NSTextField?
    private var countLabel: NSTextField?
    private var buttons: [NSButton] = []
    private var entries: [HistoryEntry] = []
    private var selectedIndex: Int?
    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailOrder: [String] = []
    private let thumbnailCacheLimit = 120
    private var thumbnailLoadGeneration = 0
    private var historyObserver: NSObjectProtocol?
    private var lastGridWidth: CGFloat = 0

    private let cardSize = CGSize(width: 210, height: 176)
    private let gridGap: CGFloat = 14
    private let gridInset: CGFloat = 18

    public init(store: HistoryStore = .shared, pinBoard: PinBoard) {
        self.store = store
        self.pinBoard = pinBoard
        super.init()
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    public func showWindow() {
        ensureWindow()
        reload()
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func makeSnapshotContentView() -> NSView? {
        ensureWindow()
        reload(synchronously: true)
        if entries.count > 1 {
            select(index: 1)
        }
        lastGridWidth = 0
        layoutSubtreeAndGrid(force: true)
        guard let window, let root = window.contentView else { return nil }
        let dark = NSAppearance(named: .darkAqua)
        window.appearance = dark
        root.appearance = dark
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor
        root.layoutSubtreeIfNeeded()
        layoutSubtreeAndGrid(force: true)
        return root
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let window = HistoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史记录"
        window.minSize = NSSize(width: 560, height: 380)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let root = HistoryBrowserRootView()
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.relayoutGrid() }
        window.contentView = root
        rootView = root

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = makeButton(title: "复制", symbol: "doc.on.doc", action: #selector(copySelected))
        let pinButton = makeButton(title: "贴图", symbol: "pin", action: #selector(pinSelected))
        let saveButton = makeButton(title: "保存…", symbol: "square.and.arrow.down", action: #selector(saveSelected))
        let finderButton = makeButton(title: "Finder", symbol: "folder", action: #selector(revealSelected))
        let deleteButton = makeButton(title: "删除", symbol: "trash", action: #selector(deleteSelected))
        buttons = [copyButton, pinButton, saveButton, finderButton, deleteButton]
        for button in buttons {
            toolbar.addArrangedSubview(button)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        self.countLabel = countLabel
        toolbar.addArrangedSubview(countLabel)

        let clearButton = makeButton(title: "清空", symbol: "trash.slash", action: #selector(clearHistory))
        toolbar.addArrangedSubview(clearButton)
        root.addSubview(toolbar)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        scrollView = scroll

        let grid = HistoryGridView()
        grid.onSelect = { [weak self] index in self?.select(index: index) }
        grid.onActivate = { [weak self] index in
            self?.select(index: index)
            self?.pinSelected()
        }
        gridView = grid
        scroll.documentView = grid

        let empty = NSTextField(labelWithString: "还没有截图历史\n按 F1 截图，结果会自动保存在这里")
        empty.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        empty.maximumNumberOfLines = 2
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(empty)
        emptyLabel = empty

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        self.window = window
        if historyObserver == nil {
            historyObserver = NotificationCenter.default.addObserver(
                forName: .myPasteHistoryDidChange,
                object: store,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.window?.isVisible == true else { return }
                    self.reload()
                }
            }
        }
    }

    private func makeButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func reload(synchronously: Bool = false) {
        entries = store.entries()
        thumbnailLoadGeneration += 1
        if let selectedIndex, selectedIndex >= entries.count {
            self.selectedIndex = nil
        }
        gridView?.rebuild(entries: entries) { [weak self] entry in
            self?.cachedThumbnail(for: entry)
        }
        emptyLabel?.isHidden = !entries.isEmpty
        countLabel?.stringValue = entries.isEmpty ? "" : "共 \(entries.count) 张 · 上限 \(AppSettings.shared.historyLimit) 张"
        refreshButtons()
        layoutSubtreeAndGrid(force: true)
        if synchronously {
            for entry in entries where thumbnails[entry.id] == nil {
                if let image = Self.loadThumbnailImage(entry) {
                    storeThumbnail(image, for: entry.id)
                    if let index = entries.firstIndex(where: { $0.id == entry.id }),
                       let cards = gridView?.cards, cards.indices.contains(index) {
                        cards[index].thumbnail = image
                    }
                }
            }
        } else {
            loadMissingThumbnailsAsync()
        }
    }

    private func cachedThumbnail(for entry: HistoryEntry) -> NSImage? {
        guard let image = thumbnails[entry.id] else { return nil }
        thumbnailOrder.removeAll { $0 == entry.id }
        thumbnailOrder.append(entry.id)
        return image
    }

    private func storeThumbnail(_ image: NSImage, for id: String) {
        thumbnails[id] = image
        thumbnailOrder.removeAll { $0 == id }
        thumbnailOrder.append(id)
        while thumbnailOrder.count > thumbnailCacheLimit, let oldest = thumbnailOrder.first {
            thumbnailOrder.removeFirst()
            thumbnails.removeValue(forKey: oldest)
        }
    }

    private func loadMissingThumbnailsAsync() {
        let generation = thumbnailLoadGeneration
        let pending = entries.filter { thumbnails[$0.id] == nil }
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for entry in pending {
                guard let image = Self.loadThumbnailImage(entry) else { continue }
                DispatchQueue.main.async {
                    guard let self, self.thumbnailLoadGeneration == generation else { return }
                    self.storeThumbnail(image, for: entry.id)
                    if let index = self.entries.firstIndex(where: { $0.id == entry.id }),
                       let cards = self.gridView?.cards, cards.indices.contains(index) {
                        cards[index].thumbnail = image
                    }
                }
            }
        }
    }

    private nonisolated static func loadThumbnailImage(_ entry: HistoryEntry) -> NSImage? {
        if FileManager.default.fileExists(atPath: entry.thumbnailURL.path),
           let image = NSImage(contentsOf: entry.thumbnailURL) {
            return image
        }
        // 缩略图缺失时用 ImageIO 降采样原图，避免把全分辨率图载入内存缓存
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    private func select(index: Int) {
        selectedIndex = index
        gridView?.setSelectedIndex(index)
        refreshButtons()
    }

    private var selectedEntry: HistoryEntry? {
        guard let selectedIndex, entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    private func refreshButtons() {
        let enabled = selectedEntry != nil
        for button in buttons {
            button.isEnabled = enabled
        }
    }

    @objc private func copySelected() {
        guard let entry = selectedEntry, let image = loadImage(entry) else { return }
        PasteboardWriter.writeImage(image)
        if AppSettings.shared.playSound {
            NSSound(named: "Tink")?.play()
        }
    }

    @objc private func pinSelected() {
        guard let entry = selectedEntry, let image = loadImage(entry) else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        pinBoard.present(
            image: image,
            at: nil,
            screen: screen,
            scale: max(1, screen.backingScaleFactor)
        )
    }

    @objc private func saveSelected() {
        guard let entry = selectedEntry, let image = loadImage(entry), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = entry.url.lastPathComponent
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.shared.saveDirectory
        panel.beginSheetModal(for: window) { [weak window, weak panel] response in
            guard let window, let panel, response == .OK, let url = panel.url else { return }
            do {
                try ImageExporter.write(image, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func revealSelected() {
        guard let entry = selectedEntry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    @objc private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        selectedIndex = nil
        refreshButtons()
        // 删除在 store 队列异步执行，完成后由 didChange 通知触发 reload
        store.delete(entry, onError: { [weak self] error in self?.presentHistoryError(error) })
    }

    @objc private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空所有历史记录？"
        alert.informativeText = "此操作会删除历史目录中的所有截图，且无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.selectedIndex = nil
            self?.thumbnails.removeAll()
            self?.thumbnailOrder.removeAll()
            self?.store.clear(onError: { [weak self] error in self?.presentHistoryError(error) })
        }
    }

    private func presentHistoryError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "历史记录操作失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func loadImage(_ entry: HistoryEntry) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func layoutSubtreeAndGrid(force: Bool = false) {
        guard let rootView, let scrollView, let gridView else { return }
        rootView.layoutSubtreeIfNeeded()
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        if !force, abs(width - lastGridWidth) < 0.5 { return }
        lastGridWidth = width
        let height = gridView.layoutCards(width: width, cardSize: cardSize, gap: gridGap, inset: gridInset)
        gridView.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: max(height, scrollView.contentSize.height)
        )
        gridView.setSelectedIndex(selectedIndex)
        scrollView.documentView = gridView
    }

    private func relayoutGrid() {
        guard let scrollView, let gridView else { return }
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        if abs(width - lastGridWidth) < 0.5 { return }
        lastGridWidth = width
        let height = gridView.layoutCards(width: width, cardSize: cardSize, gap: gridGap, inset: gridInset)
        gridView.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: max(height, scrollView.contentSize.height)
        )
    }

    public func windowDidResize(_ notification: Notification) {
        layoutSubtreeAndGrid(force: true)
    }

    public func windowWillClose(_ notification: Notification) {
        entries.removeAll()
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        thumbnailLoadGeneration += 1
        if let grid = gridView {
            grid.cards.forEach { $0.removeFromSuperview() }
            grid.cards.removeAll()
        }
        gridView = nil
        scrollView = nil
        rootView = nil
        emptyLabel = nil
        countLabel = nil
        buttons.removeAll()
        selectedIndex = nil
        lastGridWidth = 0
        // 同步置空，避免关闭后立即重开时复用已清空的旧窗口
        window = nil
    }
}
