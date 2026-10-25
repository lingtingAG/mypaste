import AppKit
import MyPasteCore

@MainActor
public final class PinBoard {
    private var pins: [PinWindowController] = []

    public init() {}

    public var count: Int { pins.count }

    public var visibleCount: Int {
        pins.filter { $0.window?.isVisible == true }.count
    }

    public var hasHiddenPins: Bool {
        visibleCount < pins.count
    }

    @discardableResult
    public func present(
        image: CGImage,
        at rect: CGRect?,
        screen: NSScreen,
        scale: CGFloat,
        originalText: String? = nil,
        preferredSize: CGSize? = nil
    ) -> PinWindowController {
        var size: CGSize
        if let preferredSize {
            size = preferredSize
        } else if let rect {
            size = rect.size
        } else {
            let effectiveScale = max(1, scale)
            size = CGSize(
                width: CGFloat(image.width) / effectiveScale,
                height: CGFloat(image.height) / effectiveScale
            )
        }
        size.width = max(28, size.width)
        size.height = max(28, size.height)

        let visibleFrame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        if size.width > visibleFrame.width || size.height > visibleFrame.height {
            let factor = min(visibleFrame.width / size.width, visibleFrame.height / size.height)
            size.width = max(28, size.width * factor)
            size.height = max(28, size.height * factor)
        }

        var origin: CGPoint
        if let rect {
            origin = rect.origin
        } else {
            let mouse = NSEvent.mouseLocation
            let cascade = CGFloat(pins.count % 6) * 18
            origin = CGPoint(
                x: mouse.x + 16 + cascade,
                y: mouse.y - size.height - 16 - cascade
            )
        }
        if origin.x + size.width > visibleFrame.maxX {
            origin.x = visibleFrame.maxX - size.width
        }
        if origin.x < visibleFrame.minX {
            origin.x = visibleFrame.minX
        }
        if origin.y + size.height > visibleFrame.maxY {
            origin.y = visibleFrame.maxY - size.height
        }
        if origin.y < visibleFrame.minY {
            origin.y = visibleFrame.minY
        }

        let frame = CGRect(origin: origin, size: size)
        let controller = PinWindowController(image: image, frame: frame, originalText: originalText)
        controller.onCloseRequested = { [weak self] pin in
            self?.pins.removeAll { $0 === pin }
        }
        pins.append(controller)
        controller.show()
        return controller
    }

    public func showAll() {
        for pin in pins {
            pin.showWindowIfHidden()
        }
    }

    public func hideAll() {
        for pin in pins {
            pin.orderOut()
        }
    }

    public func closeAll() {
        for pin in Array(pins) {
            pin.closePin()
        }
        pins.removeAll()
    }
}
