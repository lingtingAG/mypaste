import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MyPasteCore

final class CoreTests: XCTestCase {
    // MARK: - Geometry

    func testNormalizedSelectionRect() {
        let rect = Geometry.selectionRect(
            from: CGPoint(x: 120, y: 80),
            to: CGPoint(x: 20, y: 10),
            in: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 10, width: 100, height: 70))
    }

    func testSelectionRectClampsToBounds() {
        let rect = Geometry.selectionRect(
            from: CGPoint(x: -20, y: -10),
            to: CGPoint(x: 150, y: 200),
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testHandleHit() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(Geometry.handleHit(at: CGPoint(x: 100, y: 100), in: rect), .topLeft)
        XCTAssertEqual(Geometry.handleHit(at: CGPoint(x: 300, y: 150), in: rect), .right)
        XCTAssertEqual(Geometry.handleHit(at: CGPoint(x: 200, y: 200), in: rect), .bottom)
        XCTAssertNil(Geometry.handleHit(at: CGPoint(x: 200, y: 150), in: rect))
    }

    func testHandleHitCornerPriorityWithLargeTolerance() {
        // 小选区 + 大 tolerance 时角与边热区重叠，角必须优先且结果稳定
        let rect = CGRect(x: 100, y: 100, width: 20, height: 20)
        for _ in 0..<10 {
            XCTAssertEqual(Geometry.handleHit(at: CGPoint(x: 100, y: 100), in: rect, tolerance: 15), .topLeft)
            XCTAssertEqual(Geometry.handleHit(at: CGPoint(x: 120, y: 120), in: rect, tolerance: 15), .bottomRight)
        }
    }

    func testResizeRectMinimumSizeAndBounds() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let resized = Geometry.resizedRect(
            rect,
            handle: .topLeft,
            to: CGPoint(x: 250, y: 250),
            in: CGRect(x: 0, y: 0, width: 400, height: 400),
            minSize: 8
        )
        XCTAssertEqual(resized, CGRect(x: 192, y: 192, width: 8, height: 8))
    }

    func testMovedRectStaysInsideBounds() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 50)
        let moved = Geometry.movedRect(rect, by: CGPoint(x: -100, y: 500), in: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(moved, CGRect(x: 0, y: 50, width: 100, height: 50))
    }

    func testPixelRectRounding() {
        let rect = Geometry.pixelRect(
            for: CGRect(x: 10.2, y: 20.7, width: 100.1, height: 50.2),
            scale: 2
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 41, width: 201, height: 101))
    }

    func testPointRectInvertsPixelRectWithinHalfPixel() {
        let rect = CGRect(x: 5.25, y: 7.4, width: 100.5, height: 40.25)
        let scale: CGFloat = 1.5
        let pixel = Geometry.pixelRect(for: rect, scale: scale)
        let restored = Geometry.pointRect(for: pixel, scale: scale)
        let tolerance = 0.5 / scale + 1e-9
        XCTAssertEqual(restored.minX, rect.minX, accuracy: tolerance)
        XCTAssertEqual(restored.minY, rect.minY, accuracy: tolerance)
        XCTAssertEqual(restored.maxX, rect.maxX, accuracy: tolerance)
        XCTAssertEqual(restored.maxY, rect.maxY, accuracy: tolerance)
        // scale 非法时退回空矩形，避免除零
        XCTAssertEqual(Geometry.pointRect(for: pixel, scale: 0), .zero)
    }

    func testDistanceToSegment() {
        let distance = Geometry.distance(
            from: CGPoint(x: 0, y: 5),
            toSegment: CGPoint(x: -10, y: 0),
            CGPoint(x: 10, y: 0)
        )
        XCTAssertEqual(distance, 5, accuracy: 0.001)
    }

    // MARK: - Color and clipboard parsing

    func testHexColorParsing() {
        XCTAssertEqual(RGBAColor(hexString: "#FF0000")?.hexString, "#FF0000")
        XCTAssertEqual(RGBAColor(hexString: "#0f0")?.hexString, "#00FF00")
        XCTAssertEqual(try XCTUnwrap(RGBAColor(hexString: "#11223380")).alpha, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertNil(RGBAColor(hexString: "not-a-color"))
    }

    func testClipboardColorParsing() {
        XCTAssertEqual(ClipboardCard.parseColor("#00A3FF")?.hexString, "#00A3FF")
        XCTAssertEqual(ClipboardCard.parseColor("rgb(255, 0, 0)")?.hexString, "#FF0000")
        XCTAssertEqual(ClipboardCard.parseColor("rgba(0, 255, 0, 0.5)")?.alpha ?? 0, 0.5, accuracy: 0.001)
        // CSS 允许 alpha 使用百分比，解析失败不应静默回退为不透明
        XCTAssertEqual(ClipboardCard.parseColor("rgba(0, 255, 0, 50%)")?.alpha ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(ClipboardCard.parseColor("rgba(0, 255, 0, abc)"))
        XCTAssertEqual(ClipboardCard.parseColor("0x336699")?.hexString, "#336699")
        XCTAssertEqual(ClipboardCard.parseColor("红色")?.hexString, RGBAColor.red.hexString)
        XCTAssertNil(ClipboardCard.parseColor("123456"))
        XCTAssertNil(ClipboardCard.parseColor("hello world"))
    }

    func testColorCardRendering() throws {
        let card = try XCTUnwrap(ClipboardCard.makeColorCard(color: .blue, rawText: "#0A84FF"))
        XCTAssertEqual(card.image.width, 880)
        XCTAssertEqual(card.image.height, 400)
        XCTAssertEqual(card.displaySize, CGSize(width: 440, height: 200))
        XCTAssertNotNil(ImageExporter.pngData(card.image))
    }

    func testTextCardRendering() throws {
        let card = try XCTUnwrap(ClipboardCard.make(from: "Hello MyPaste\n第二行文本，用于验证自动换行和圆角卡片渲染。"))
        XCTAssertGreaterThan(card.image.width, 200)
        XCTAssertGreaterThan(card.image.height, 40)
        XCTAssertEqual(card.image.width, Int(card.displaySize.width * 2))
    }

    // MARK: - Shortcuts

    func testShortcutDisplayStrings() {
        XCTAssertEqual(Shortcut.capture.displayString, "F1")
        XCTAssertEqual(Shortcut.pin.displayString, "F3")
        XCTAssertEqual(Shortcut(keyCode: 0, modifiers: UInt32(cmdKey) | UInt32(shiftKey)).displayString, "⇧⌘A")
    }

    func testShortcutFromEventFiltersInvalidKeys() throws {
        let letter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_A)
        ))
        let shortcut = try XCTUnwrap(Shortcut.from(event: letter))
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertTrue(shortcut.hasCommand)
        XCTAssertTrue(shortcut.hasShift)
        XCTAssertFalse(shortcut.hasOption)

        // 纯修饰键不能作为快捷键
        let modifier = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_Command)
        ))
        XCTAssertNil(Shortcut.from(event: modifier))
    }

    func testShortcutCodableRoundTrip() throws {
        let shortcut = Shortcut(keyCode: 15, modifiers: UInt32(optionKey))
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), shortcut)
    }

    // MARK: - Image composition

    func testAverageColorOrientation() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 20,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        let topColor = try XCTUnwrap(AnnotationRenderer.averageColor(of: image, at: CGPoint(x: 10, y: 2)))
        let bottomColor = try XCTUnwrap(AnnotationRenderer.averageColor(of: image, at: CGPoint(x: 10, y: 17)))
        XCTAssertGreaterThan(topColor.red, 0.8)
        XCTAssertLessThan(topColor.blue, 0.2)
        XCTAssertGreaterThan(bottomColor.blue, 0.8)
        XCTAssertLessThan(bottomColor.red, 0.2)
    }

    func testComposeWithoutAnnotationsCrops() throws {
        let image = try makeTestImage(width: 800, height: 600)
        let cropped = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: CGRect(x: 50, y: 40, width: 200, height: 100),
            screenScale: 2,
            annotations: []
        ))
        XCTAssertEqual(cropped.width, 400)
        XCTAssertEqual(cropped.height, 200)
    }

    func testComposeFractionalSelectionHasOpaqueEdges() throws {
        let image = try makeTestImage(width: 400, height: 300)
        let annotation = Annotation(
            kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)),
            color: .green,
            lineWidth: 4
        )
        // 分数选区 + 非整数 scale：pixelRect 比 selection.size*scale 多出的像素不得留透明缝
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.5),
            screenScale: 1.5,
            annotations: [annotation]
        ))
        let sampler = PixelSampler(image: composed)
        let edgePoints = [
            CGPoint(x: composed.width - 1, y: 0),
            CGPoint(x: 0, y: composed.height - 1),
            CGPoint(x: composed.width - 1, y: composed.height - 1),
            CGPoint(x: composed.width - 1, y: composed.height / 2),
            CGPoint(x: composed.width / 2, y: composed.height - 1),
        ]
        for point in edgePoints {
            let color = try XCTUnwrap(sampler.color(at: point))
            XCTAssertEqual(color.alpha, 1, accuracy: 0.01, "边缘像素 \(point) 不应透明")
        }
    }

    func testCropClampsSelectionToImageBounds() throws {
        let image = try makeTestImage(width: 40, height: 30)
        // 选区越出图像左上角：裁剪结果必须收缩到图像范围内
        let cropped = try XCTUnwrap(ImageComposer.crop(
            image,
            selectionRect: CGRect(x: -10, y: -10, width: 30, height: 20),
            scale: 2
        ))
        XCTAssertEqual(cropped.width, 40)
        XCTAssertEqual(cropped.height, 20)
        // 完全越界返回 nil，而不是空图
        XCTAssertNil(ImageComposer.crop(
            image,
            selectionRect: CGRect(x: 100, y: 100, width: 20, height: 20),
            scale: 1
        ))
    }

    func testComposeFilledAnnotation() throws {
        let image = try makeTestImage(width: 400, height: 300)
        let annotation = Annotation(
            kind: .rectangle(CGRect(x: 20, y: 20, width: 100, height: 60)),
            color: .green,
            lineWidth: 4,
            filled: true
        )
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: CGRect(x: 10, y: 10, width: 200, height: 150),
            screenScale: 2,
            annotations: [annotation]
        ))
        XCTAssertEqual(composed.width, 380)
        XCTAssertEqual(composed.height, 280)
        let center = try XCTUnwrap(AnnotationRenderer.averageColor(of: composed, at: CGPoint(x: 100, y: 100)))
        XCTAssertGreaterThan(center.green, 0.6)
        XCTAssertLessThan(center.red, 0.4)
        XCTAssertLessThan(center.blue, 0.6)
    }

    func testTextAnnotationHasTransparentBackground() throws {
        let background = RGBAColor(red: 0.12, green: 0.45, blue: 0.78)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 180,
            height: 90,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(background.nsColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 180, height: 90))
        let image = try XCTUnwrap(context.makeImage())
        let annotation = Annotation(
            kind: .text(origin: CGPoint(x: 20, y: 20), string: "Hi", fontSize: 24),
            color: .red,
            lineWidth: 4
        )
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: CGRect(x: 0, y: 0, width: 180, height: 90),
            screenScale: 1,
            annotations: [annotation]
        ))
        let padding = try XCTUnwrap(
            AnnotationRenderer.averageColor(of: composed, at: CGPoint(x: 22, y: 35))
        )
        XCTAssertEqual(padding.red, background.red, accuracy: 0.03)
        XCTAssertEqual(padding.green, background.green, accuracy: 0.03)
        XCTAssertEqual(padding.blue, background.blue, accuracy: 0.03)
    }

    func testAllAnnotationTypesRenderWithoutCrash() throws {
        let image = try makeTestImage(width: 600, height: 400)
        let annotations: [Annotation] = [
            Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 80, height: 40)), color: .red),
            Annotation(kind: .ellipse(CGRect(x: 100, y: 10, width: 80, height: 40)), color: .blue, filled: true),
            Annotation(kind: .arrow(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 140, y: 140)), color: .orange),
            Annotation(kind: .pen(points: [CGPoint(x: 20, y: 150), CGPoint(x: 40, y: 140), CGPoint(x: 80, y: 180)]), color: .purple),
            Annotation(kind: .marker(points: [CGPoint(x: 30, y: 210), CGPoint(x: 160, y: 210)]), color: .yellow),
            Annotation(kind: .text(origin: CGPoint(x: 20, y: 240), string: "Hello 截图", fontSize: 20), color: .red),
            Annotation(kind: .mosaic(CGRect(x: 200, y: 20, width: 100, height: 80)), color: .red),
            Annotation(kind: .blur(CGRect(x: 300, y: 20, width: 100, height: 80)), color: .red),
            Annotation(kind: .number(center: CGPoint(x: 250, y: 160), value: 1), color: .red),
        ]
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            screenScale: 2,
            annotations: annotations
        ))
        XCTAssertEqual(composed.width, 600)
        XCTAssertEqual(composed.height, 400)
        XCTAssertNotNil(ImageExporter.pngData(composed))
    }

    func testMosaicAndBlurSampleCorrectRegion() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 400,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
        let image = try XCTUnwrap(context.makeImage())

        let annotations = [
            Annotation(kind: .mosaic(CGRect(x: 10, y: 10, width: 100, height: 50)), color: .green, lineWidth: 4),
            Annotation(kind: .blur(CGRect(x: 10, y: 110, width: 100, height: 50)), color: .green, lineWidth: 4),
        ]
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            screenScale: 1,
            annotations: annotations
        ))
        XCTAssertEqual(composed.width, 400)
        XCTAssertEqual(composed.height, 200)
        let mosaicCenter = try XCTUnwrap(AnnotationRenderer.averageColor(of: composed, at: CGPoint(x: 50, y: 30)))
        let blurCenter = try XCTUnwrap(AnnotationRenderer.averageColor(of: composed, at: CGPoint(x: 50, y: 130)))
        XCTAssertGreaterThan(mosaicCenter.red, 0.8)
        XCTAssertLessThan(mosaicCenter.blue, 0.2)
        XCTAssertGreaterThan(blurCenter.blue, 0.8)
        XCTAssertLessThan(blurCenter.red, 0.2)
    }

    func testComposeFractionalScaleMatchesPixelRect() throws {
        let image = try makeTestImage(width: 600, height: 400)
        let selection = CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.5)
        let composed = try XCTUnwrap(ImageComposer.compose(
            baseImage: image,
            selectionRect: selection,
            screenScale: 1.5,
            annotations: []
        ))
        let expected = Geometry.pixelRect(for: selection, scale: 1.5)
        XCTAssertEqual(composed.width, Int(expected.width))
        XCTAssertEqual(composed.height, Int(expected.height))
        XCTAssertEqual(composed.width, 151)
    }

    func testAnnotationHitTesting() {
        let annotation = Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 50)))
        XCTAssertTrue(annotation.hitTest(CGPoint(x: 60, y: 30)))
        XCTAssertFalse(annotation.hitTest(CGPoint(x: 300, y: 300)))

        let arrow = Annotation(kind: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 52)))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 10, y: 90)))
    }

    // MARK: - History

    func testHistoryRecordListAndPrune() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 120, height: 80)

        for _ in 0..<3 {
            _ = try store.recordSync(image, limit: 2)
        }

        let entries = store.entries()
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.thumbnailURL.path))
            XCTAssertEqual(entry.pixelSize, CGSize(width: 120, height: 80))
        }
    }

    func testHistoryThumbnailIsJPEGAndSmallerThanPNG() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        // 带噪点的图才能体现 PNG 与 JPEG 的体积差异
        let image = try makeNoisyTestImage(width: 800, height: 600)
        let entry = try store.recordSync(image, limit: 10)

        XCTAssertEqual(
            entry.thumbnailURL.pathExtension.lowercased(),
            "jpg",
            "缩略图改用 JPEG 落盘"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.thumbnailURL.path))

        // 缩略图长边不超过上限：卡片显示区 2x 下也只需 392px
        let thumb = try XCTUnwrap(NSImage(contentsOf: entry.thumbnailURL))
        XCTAssertLessThanOrEqual(
            max(thumb.size.width, thumb.size.height),
            HistoryStore.thumbnailMaxPixel + 0.5
        )

        // 同尺寸 PNG 缩略图明显更大：这就是本项省下的磁盘空间
        let pixel = try XCTUnwrap(HistoryStore.makeThumbnail(image, maxPixel: HistoryStore.thumbnailMaxPixel))
        let pngData = try XCTUnwrap(ImageExporter.pngData(pixel))
        let jpegData = try Data(contentsOf: entry.thumbnailURL)
        XCTAssertLessThan(jpegData.count, pngData.count / 2, "JPEG 缩略图应显著小于 PNG")
    }

    func testHistoryDeleteAndClearAreAsyncAndConsistent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 60, height: 40)
        _ = try store.recordSync(image, limit: 10)
        _ = try store.recordSync(image, limit: 10)
        XCTAssertEqual(store.entries().count, 2)

        // delete/clear 走内部队列，entries() 与之串行，不会读到竞争状态
        let deleted = expectation(description: "history change after delete")
        let observer = NotificationCenter.default.addObserver(
            forName: .myPasteHistoryDidChange,
            object: store,
            queue: .main
        ) { _ in deleted.fulfill() }
        store.delete(store.entries()[0])
        wait(for: [deleted], timeout: 5)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(store.entries().count, 1)

        store.clear()
        // clear 异步执行，通过队列串行的 entries() 观察最终状态
        let deadline = Date().addingTimeInterval(5)
        while !store.entries().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(store.entries().count, 0)
    }

    func testHistoryPruneByDiskBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 200, height: 150)

        var entries: [HistoryEntry] = []
        for _ in 0..<4 {
            entries.append(try store.recordSync(image, limit: 100))
        }
        let footprint = entries[0].diskFootprint
        XCTAssertGreaterThan(entries[0].fileSize, 0)
        XCTAssertGreaterThan(entries[0].thumbnailFileSize, 0)
        XCTAssertEqual(footprint, entries[0].fileSize + entries[0].thumbnailFileSize)
        // 预算只够 2 个文件（含缩略图）：从最旧删除，保留最新两条
        try store.prune(limit: 100, diskLimitBytes: footprint * 2)
        let remaining = store.entries()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.id)), Set(entries.suffix(2).map(\.id)))

        // 预算小于单文件时至少保留最新一条
        try store.prune(limit: 100, diskLimitBytes: 1)
        XCTAssertEqual(store.entries().count, 1)
        XCTAssertEqual(store.entries()[0].id, entries.last?.id)
    }

    func testHistoryDeleteTreatsMissingFilesAsSuccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 40, height: 30)
        let entry = try store.recordSync(image, limit: 10)
        try FileManager.default.removeItem(at: entry.url)
        try FileManager.default.removeItem(at: entry.thumbnailURL)

        let changed = expectation(description: "history change")
        let observer = NotificationCenter.default.addObserver(forName: .myPasteHistoryDidChange, object: store, queue: .main) { _ in
            changed.fulfill()
        }
        store.delete(entry, onError: { error in XCTFail("missing file should not report error: \(error)") })
        wait(for: [changed], timeout: 5)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testHistoryClearReportsIOError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 40, height: 30)
        _ = try store.recordSync(image, limit: 10)
        // 把历史目录替换为普通文件：contentsOfDirectory 必然失败且非"文件不存在"
        try FileManager.default.removeItem(at: root)
        FileManager.default.createFile(atPath: root.path, contents: Data([0]))

        let failed = expectation(description: "clear error reported")
        store.clear(onError: { _ in failed.fulfill() })
        wait(for: [failed], timeout: 5)
    }

    // MARK: - Effect cache

    func testMosaicEffectClipsLocalRectToImageBounds() throws {
        let image = try makeTestImage(width: 40, height: 40)
        let source = RenderSource(image: image, originInImage: .zero, pixelsPerPoint: 2)
        // 马赛克矩形越过源图左/上边界：绘制矩形必须收缩到实际可采样区域，
        // 否则小块图会被拉伸铺满原 rect（与 blur 路径一致）
        let effect = try XCTUnwrap(AnnotationRenderer.makeMosaicEffect(
            CGRect(x: -10, y: -10, width: 30, height: 30),
            lineWidth: 4,
            source: source
        ))
        XCTAssertEqual(effect.localRect, CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testEffectCacheHitIdentityAndEviction() throws {
        let image = try makeTestImage(width: 40, height: 30)
        let other = try makeTestImage(width: 40, height: 30)
        let cache = AnnotationEffectCache(limit: 2)
        let effect = AnnotationEffectCache.Effect(image: image, localRect: .zero)
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        func key(_ img: CGImage, _ r: CGRect) -> AnnotationEffectCache.Key {
            AnnotationEffectCache.Key(image: img, origin: .zero, scale: 2, isBlur: false, rect: r, lineWidth: 4)
        }
        var makes = 0
        let make = { () -> AnnotationEffectCache.Effect? in makes += 1; return effect }

        XCTAssertNotNil(cache.effect(for: key(image, rect), make: make))
        XCTAssertNotNil(cache.effect(for: key(image, rect), make: make))
        XCTAssertEqual(makes, 1, "same key must hit cache")

        // 几何参数相同但源图不同：不得串用（键含图像身份）
        XCTAssertNotNil(cache.effect(for: key(other, rect), make: make))
        XCTAssertEqual(makes, 2)

        // 超出上限驱逐最旧：首个 key 再取需重算
        XCTAssertNotNil(cache.effect(for: key(image, rect.offsetBy(dx: 5, dy: 0)), make: make))
        XCTAssertEqual(makes, 3)
        XCTAssertNotNil(cache.effect(for: key(image, rect), make: make))
        XCTAssertEqual(makes, 4)

        // 独立实例之间互不共享
        let fresh = AnnotationEffectCache()
        XCTAssertNotNil(fresh.effect(for: key(image, rect), make: make))
        XCTAssertEqual(makes, 5)
    }

    func testHistoryRecordReusesProvidedPNGData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 80, height: 60)
        let png = try XCTUnwrap(ImageExporter.pngData(image))
        let entry = try store.recordSync(image, pngData: png, limit: 10)
        XCTAssertEqual(try Data(contentsOf: entry.url), png)
        XCTAssertEqual(entry.fileSize, Int64(png.count))
    }

    func testHistoryRecordAsyncCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 40, height: 30)
        let recorded = expectation(description: "record completion")
        store.record(image, completion: { entry in
            XCTAssertNotNil(entry)
            recorded.fulfill()
        }, onError: { error in
            XCTFail("unexpected error: \(error)")
        })
        wait(for: [recorded], timeout: 5)
        XCTAssertEqual(store.entries().count, 1)
    }

    func testHistoryRecordReportsWriteError() throws {
        // 历史根目录被同名的普通文件占用：写入必然失败，异步接口必须回调 onError
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: root.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 10, height: 10)

        let failed = expectation(description: "record error")
        store.record(image, completion: { entry in
            XCTAssertNil(entry)
        }, onError: { _ in
            failed.fulfill()
        })
        wait(for: [failed], timeout: 5)
    }

    func testHistoryPruneAsyncReportsIOError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 40, height: 30)
        _ = try store.recordSync(image, limit: 10)
        _ = try store.recordSync(image, limit: 10)
        // 用不可变标记让最旧的原图删除失败（不依赖运行用户权限），pruneAsync 必须上报而非静默
        let oldest = try XCTUnwrap(store.entries().last)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: oldest.url.path
        )
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: oldest.url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: oldest.url.path)
            try? FileManager.default.removeItem(at: root)
        }

        let failed = expectation(description: "prune error")
        store.pruneAsync(limit: 1, onError: { _ in failed.fulfill() })
        wait(for: [failed], timeout: 5)
    }

    func testHistoryRecordReportsPruneErrorSeparately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 40, height: 30)
        _ = try store.recordSync(image, limit: 10)
        _ = try store.recordSync(image, limit: 10)
        // 让最旧的原图无法删除，强制 record 内部 prune 失败
        let oldest = try XCTUnwrap(store.entries().last)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: oldest.url.path
        )
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: oldest.url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: oldest.url.path)
            try? FileManager.default.removeItem(at: root)
        }

        let completed = expectation(description: "record completion")
        let pruneFailed = expectation(description: "prune error")
        store.record(image, limit: 1, completion: { entry in
            // 写入成功，结果仍交付；清理失败不得走写入错误通道
            XCTAssertNotNil(entry)
            completed.fulfill()
        }, onError: { error in
            XCTFail("write should succeed: \(error)")
        }, onPruneError: { _ in
            pruneFailed.fulfill()
        })
        wait(for: [completed, pruneFailed], timeout: 5)
        // 清理继续推进到只剩 1 条计数，但不可变的旧图仍留在磁盘上
        XCTAssertEqual(store.entries().count, 2)
    }

    func testHistoryPruneContinuesPastUndeletableFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 40, height: 30)
        _ = try store.recordSync(image, limit: 10)
        _ = try store.recordSync(image, limit: 10)
        _ = try store.recordSync(image, limit: 10)
        // 最旧原图不可删除：错误应被收集，但不能中断整轮清理
        let entries = store.entries()
        let oldest = try XCTUnwrap(entries.last)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: oldest.url.path
        )
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: oldest.url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: oldest.url.path)
            try? FileManager.default.removeItem(at: root)
        }

        // 字节上限小于任意单条记录：清理应继续删掉次新记录，直到只剩最新一条（加上删不掉的僵尸文件）
        XCTAssertThrowsError(try store.prune(limit: 100, diskLimitBytes: 1))
        let remaining = store.entries().map(\.id)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains(oldest.id))
        XCTAssertTrue(remaining.contains(entries[0].id))
        XCTAssertFalse(remaining.contains(entries[1].id))
    }

    // MARK: - Pixel sampling

    func testPixelSamplerMatchesOrientationAndBounds() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 20,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        let sampler = PixelSampler(image: image)

        // 与 averageColor 相同的 top-left/y-down 像素坐标约定：y=2 取到红色
        let top = try XCTUnwrap(sampler.color(at: CGPoint(x: 10, y: 2)))
        let bottom = try XCTUnwrap(sampler.color(at: CGPoint(x: 10, y: 17)))
        let averageTop = try XCTUnwrap(AnnotationRenderer.averageColor(of: image, at: CGPoint(x: 10, y: 2)))
        let averageBottom = try XCTUnwrap(AnnotationRenderer.averageColor(of: image, at: CGPoint(x: 10, y: 17)))
        XCTAssertEqual(top.red, averageTop.red, accuracy: 0.02)
        XCTAssertEqual(top.blue, averageTop.blue, accuracy: 0.02)
        XCTAssertEqual(bottom.red, averageBottom.red, accuracy: 0.02)
        XCTAssertEqual(bottom.blue, averageBottom.blue, accuracy: 0.02)
        XCTAssertGreaterThan(top.red, 0.8)
        XCTAssertGreaterThan(bottom.blue, 0.8)
        XCTAssertNil(sampler.color(at: CGPoint(x: -1, y: 0)))
        // 负分数坐标：Int() 向零截断不得把它当成第 0 列/行
        XCTAssertNil(sampler.color(at: CGPoint(x: -0.5, y: 0)))
        XCTAssertNil(sampler.color(at: CGPoint(x: 0, y: -0.5)))
        XCTAssertNil(AnnotationRenderer.averageColor(of: image, at: CGPoint(x: -0.5, y: 0)))
        XCTAssertNil(sampler.color(at: CGPoint(x: 0, y: 20)))
    }

    // MARK: - Export and settings

    func testExporterFormatBranches() throws {
        let image = try makeTestImage(width: 40, height: 30)
        let png = try XCTUnwrap(ImageExporter.data(for: image, fileExtension: "png"))
        let jpeg = try XCTUnwrap(ImageExporter.data(for: image, fileExtension: "jpg"))
        let tiff = try XCTUnwrap(ImageExporter.data(for: image, fileExtension: "tiff"))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertTrue(tiff.starts(with: Data([0x49, 0x49])) || tiff.starts(with: Data([0x4D, 0x4D])))
        // 未知格式不得静默回退 PNG，否则写出扩展名与内容不符的文件
        XCTAssertNil(ImageExporter.data(for: image, fileExtension: "unknown"))
    }

    func testExporterWriteCreatesDirectoriesAndFormats() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPasteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try makeTestImage(width: 20, height: 10)

        // 不存在的多级目录需自动创建，扩展名决定编码格式
        let jpegURL = dir.appendingPathComponent("nested/shot.jpeg")
        try ImageExporter.write(image, to: jpegURL)
        XCTAssertEqual(try Data(contentsOf: jpegURL).prefix(2), Data([0xFF, 0xD8]))

        // 无扩展名默认 PNG
        let plainURL = dir.appendingPathComponent("shot")
        try ImageExporter.write(image, to: plainURL)
        XCTAssertEqual(try Data(contentsOf: plainURL).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))

        // 不支持的扩展名显式报错，不写出内容与扩展名不符的文件
        let webpURL = dir.appendingPathComponent("shot.webp")
        XCTAssertThrowsError(try ImageExporter.write(image, to: webpURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: webpURL.path))
    }

    func testPasteboardImageAndTextRoundTrip() throws {
        // 用独立命名剪贴板，避免测试污染用户剪贴板；结束后释放，避免残留到 pasteboard server
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyPasteTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = try makeTestImage(width: 32, height: 24)
        PasteboardWriter.writeImage(image, to: pasteboard)
        guard case let .image(restored, _)? = PasteboardReader.read(from: pasteboard) else {
            return XCTFail("expected image content")
        }
        XCTAssertEqual(restored.width, 32)
        XCTAssertEqual(restored.height, 24)

        PasteboardWriter.writeText("hello", to: pasteboard)
        guard case let .text(text)? = PasteboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text, "hello")
    }

    func testTimestampedFileNames() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = ImageExporter.timestampedFileName(date: date)
        XCTAssertTrue(name.hasPrefix("MyPaste_"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertEqual(name, ImageExporter.timestampedFileName(date: date))
        XCTAssertTrue(ImageExporter.timestampBase(date: date).hasPrefix("MyPaste_"))
        XCTAssertFalse(ImageExporter.timestampBase(date: date).contains("."))
    }

    func testSettingsClamping() throws {
        // 固定 suite 名：removePersistentDomain 不会删除底层 plist，随机名会导致每次运行新增残留文件
        let suite = "com.mypaste.tests.settings"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.toolFontSize = 500
        XCTAssertEqual(settings.toolFontSize, 120)
        settings.toolFontSize = 1
        XCTAssertEqual(settings.toolFontSize, 10)
        settings.historyLimit = 1
        XCTAssertEqual(settings.historyLimit, 10)
        settings.historyDiskLimitMB = 1
        XCTAssertEqual(settings.historyDiskLimitMB, 100)
        XCTAssertEqual(TextMetrics.clampedFontSize(42), 42)
    }

    // MARK: - v1.1: secure writes, save formats, tool memory

    func testSecureFileWriterRestrictsFileAndDirectoryPermissions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("MyPasteSecure-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("nested", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let url = dir.appendingPathComponent("shot.png")
        let data = Data([0x01, 0x02, 0x03])
        try SecureFileWriter.write(data, to: url)

        let filePerms = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(filePerms.intValue, 0o600)
        let dirPerms = try XCTUnwrap(fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(dirPerms.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testSecureFileWriterDoesNotChangeExistingDirectoryPermissions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPasteSecure-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        try SecureFileWriter.ensureDirectory(at: dir)
        let perms = try XCTUnwrap(fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue, 0o755)
    }

    func testHistoryStoreWritesPrivateFilesAndDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("MyPasteHistoryPerm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let image = try makeTestImage(width: 24, height: 16)
        let recorded = expectation(description: "record")
        var entry: HistoryEntry?
        store.record(image, completion: { value in
            entry = value
            recorded.fulfill()
        })
        wait(for: [recorded], timeout: 5)
        let saved = try XCTUnwrap(entry)
        for url in [saved.url, saved.thumbnailURL] {
            let perms = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(perms.intValue, 0o600)
        }
        let dirPerms = try XCTUnwrap(fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(dirPerms.intValue, 0o700)
    }

    func testExporterWriteProducesPrivateFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPasteExportPerm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")
        try ImageExporter.write(try makeTestImage(width: 20, height: 10), to: url)
        let perms = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue, 0o600)
    }

    func testSaveFormatAndJPEGQualitySettings() throws {
        let suite = "com.mypaste.tests.settings"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.saveFormat, .png)
        XCTAssertEqual(settings.jpegQuality, 0.92, accuracy: 0.001)
        settings.saveFormat = .jpeg
        XCTAssertEqual(AppSettings(defaults: defaults).saveFormat, .jpeg)
        settings.jpegQuality = 5
        XCTAssertEqual(settings.jpegQuality, 1, accuracy: 0.001)
        settings.jpegQuality = 0
        XCTAssertEqual(settings.jpegQuality, 0.1, accuracy: 0.001)
        defaults.set("bogus", forKey: "com.mypaste.saveFormat")
        XCTAssertEqual(settings.saveFormat, .png)
    }

    func testSaveFormatExtensionsAndJPEGQualityEncoding() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ImageExporter.timestampedFileName(date: date, fileExtension: "jpeg").hasSuffix(".jpeg"))
        XCTAssertTrue(ImageExporter.displayFileName(date: date, fileExtension: "tiff").hasSuffix(".tiff"))
        XCTAssertEqual(SaveFormat.allCases.map(\.fileExtension), ["png", "jpeg", "tiff"])
        let image = try makeTestImage(width: 60, height: 40)
        let high = try XCTUnwrap(ImageExporter.data(for: image, fileExtension: "jpeg", jpegQuality: 1))
        let low = try XCTUnwrap(ImageExporter.data(for: image, fileExtension: "jpeg", jpegQuality: 0.1))
        XCTAssertGreaterThan(high.count, low.count)
    }

    func testLastToolWhitelist() throws {
        let suite = "com.mypaste.tests.settings"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.lastTool, .move)
        settings.lastTool = .rectangle
        XCTAssertEqual(AppSettings(defaults: defaults).lastTool, .rectangle)
        settings.lastTool = .text
        XCTAssertEqual(settings.lastTool, .move)
        settings.lastTool = .move
        XCTAssertEqual(settings.lastTool, .move)
        defaults.set("bogus", forKey: "com.mypaste.lastTool")
        XCTAssertEqual(settings.lastTool, .move)
    }

    func testSecureFileWriterReportsPermissionFailureAndRollsBack() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPastePermFail-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")
        let original = SecureFileWriter.attributeSetter
        defer { SecureFileWriter.attributeSetter = original }
        // 目录收紧成功，文件收紧失败：必须抛错且不能留下权限不符的截图
        SecureFileWriter.attributeSetter = { path, attributes in
            if path == url.path {
                throw NSError(domain: "MyPasteTests", code: 1, userInfo: nil)
            }
            try fm.setAttributes(attributes, ofItemAtPath: path)
        }
        XCTAssertThrowsError(try SecureFileWriter.write(Data([0x01, 0x02]), to: url))
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testSecureFileWriterReportsDirectoryPermissionFailure() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPastePermFail-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        let original = SecureFileWriter.attributeSetter
        defer { SecureFileWriter.attributeSetter = original }
        SecureFileWriter.attributeSetter = { _, _ in
            throw NSError(domain: "MyPasteTests", code: 2, userInfo: nil)
        }
        XCTAssertThrowsError(try SecureFileWriter.ensurePrivateDirectory(at: dir))
    }

    // MARK: - v1.2: space-saving writes, pixel buffer gate, pin limit

    func testSpaceSavingWriterReusesSourceData() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPasteSpace-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("history.png")
        let destination = dir.appendingPathComponent("autosave.png")
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        try SecureFileWriter.write(data, to: source)
        try SpaceSavingWriter.copy(from: source, to: destination, fallbackData: data)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let perms = try XCTUnwrap(fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue, 0o600)
    }

    func testSpaceSavingWriterFallsBackWhenSourceMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPasteSpace-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("gone.png")
        let destination = dir.appendingPathComponent("autosave.png")
        let data = Data([0x01, 0x02, 0x03])
        try SpaceSavingWriter.copy(from: source, to: destination, fallbackData: data)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let perms = try XCTUnwrap(fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue, 0o600)
    }

    func testSpaceSavingWriterFallsBackWhenSourceIsNil() throws {
        // 历史写入失败时 entry == nil：自动保存必须独立写盘，保持改动前的语义
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPasteSpace-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("autosave.png")
        let data = Data([0x01, 0x02, 0x03])
        try SpaceSavingWriter.copy(from: nil, to: destination, fallbackData: data)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let perms = try XCTUnwrap(fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue, 0o600)
    }

    func testSpaceSavingWriterReplacesExistingDestination() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MyPasteSpace-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("history.png")
        let destination = dir.appendingPathComponent("autosave.png")
        let data = Data([0x10, 0x20, 0x30])
        try SecureFileWriter.write(Data([0x99, 0x99]), to: destination)
        try SecureFileWriter.write(data, to: source)
        try SpaceSavingWriter.copy(from: source, to: destination, fallbackData: data)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testPixelSamplerSamplesWithoutFullScreenBuffer() throws {
        let image = try makeTestImage(width: 24, height: 16)
        let sampler = PixelSampler(image: image)
        let point = CGPoint(x: 7, y: 3)
        // v1.3：按需单像素采样，常驻缓冲固定 1 像素，不再随源图尺寸增长
        XCTAssertEqual(sampler.residentPixelCount, 1)
        // 未 prepare 时也必须能正确取色（采样按需进行，不依赖后台预热）
        let sampled = try XCTUnwrap(sampler.color(at: point))
        XCTAssertTrue(sampler.isPrepared)
        // 与参考实现（单像素裁剪采样）一致
        let reference = try XCTUnwrap(AnnotationRenderer.averageColor(of: image, at: point))
        XCTAssertEqual(sampled.red, reference.red, accuracy: 0.01)
        XCTAssertEqual(sampled.green, reference.green, accuracy: 0.01)
        XCTAssertEqual(sampled.blue, reference.blue, accuracy: 0.01)
        // prepare 幂等，结果不漂移
        sampler.prepare()
        let afterPrepare = try XCTUnwrap(sampler.color(at: point))
        XCTAssertEqual(afterPrepare.red, sampled.red, accuracy: 0.01)
        XCTAssertEqual(afterPrepare.green, sampled.green, accuracy: 0.01)
        XCTAssertEqual(afterPrepare.blue, sampled.blue, accuracy: 0.01)
    }

    func testPinLimitSettingClamping() throws {
        let suite = "com.mypaste.tests.settings"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.pinLimit, 20)
        settings.pinLimit = 1
        XCTAssertEqual(settings.pinLimit, 5)
        settings.pinLimit = 500
        XCTAssertEqual(settings.pinLimit, 100)
    }

    // MARK: - Helpers

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<6 {
            context.setFillColor(NSColor(
                hue: CGFloat(index) / 6,
                saturation: 0.65,
                brightness: 0.9,
                alpha: 1
            ).cgColor)
            context.fill(CGRect(
                x: index * width / 7,
                y: height / 3,
                width: width / 9,
                height: height / 3
            ))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// 带随机噪点的测试图：真实截图有高频细节，压缩率才接近实际
    private func makeNoisyTestImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed % 1000) / 1000.0
        }
        for y in 0..<height {
            for x in 0..<width {
                let value = next()
                context.setFillColor(NSColor(
                    calibratedRed: value,
                    green: 1 - value,
                    blue: next(),
                    alpha: 1
                ).cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }
}
