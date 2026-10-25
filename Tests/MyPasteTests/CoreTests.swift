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

        if let first = entries.first {
            store.delete(first)
            XCTAssertEqual(store.entries().count, 1)
        }
        store.clear()
        XCTAssertEqual(store.entries().count, 0)
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
}
