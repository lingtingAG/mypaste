import AppKit

enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(in context: CGContext) {
        context.saveGState()
        context.setAllowsAntialiasing(true)
        drawCorners(in: context)
        drawFocusDot(in: context)
        context.restoreGState()
    }

    private static func drawCorners(in context: CGContext) {
        let rect = CGRect(x: 2.4, y: 2.4, width: 13.2, height: 13.2)
        let arm: CGFloat = 4.3
        let radius: CGFloat = 2.2
        let lineWidth: CGFloat = 1.55
        let bottom = rect.maxY
        let right = rect.maxX

        let paths: [NSBezierPath] = [
            {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
                path.line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
                path.curve(
                    to: CGPoint(x: rect.minX + radius, y: rect.minY),
                    controlPoint1: CGPoint(x: rect.minX, y: rect.minY),
                    controlPoint2: CGPoint(x: rect.minX, y: rect.minY)
                )
                path.line(to: CGPoint(x: rect.minX + arm, y: rect.minY))
                return path
            }(),
            {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: right - arm, y: rect.minY))
                path.line(to: CGPoint(x: right - radius, y: rect.minY))
                path.curve(
                    to: CGPoint(x: right, y: rect.minY + radius),
                    controlPoint1: CGPoint(x: right, y: rect.minY),
                    controlPoint2: CGPoint(x: right, y: rect.minY)
                )
                path.line(to: CGPoint(x: right, y: rect.minY + arm))
                return path
            }(),
            {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: bottom - arm))
                path.line(to: CGPoint(x: rect.minX, y: bottom - radius))
                path.curve(
                    to: CGPoint(x: rect.minX + radius, y: bottom),
                    controlPoint1: CGPoint(x: rect.minX, y: bottom),
                    controlPoint2: CGPoint(x: rect.minX, y: bottom)
                )
                path.line(to: CGPoint(x: rect.minX + arm, y: bottom))
                return path
            }(),
            {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: right - arm, y: bottom))
                path.line(to: CGPoint(x: right - radius, y: bottom))
                path.curve(
                    to: CGPoint(x: right, y: bottom - radius),
                    controlPoint1: CGPoint(x: right, y: bottom),
                    controlPoint2: CGPoint(x: right, y: bottom)
                )
                path.line(to: CGPoint(x: right, y: bottom - arm))
                return path
            }(),
        ]

        NSColor.black.setStroke()
        for path in paths {
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private static func drawFocusDot(in context: CGContext) {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: CGRect(x: 7.55, y: 7.55, width: 2.9, height: 2.9)).fill()
    }
}
