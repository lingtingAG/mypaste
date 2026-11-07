import CoreGraphics
import Foundation

public enum ResizeHandle: Int, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    public var movesLeftEdge: Bool {
        self == .topLeft || self == .left || self == .bottomLeft
    }

    public var movesRightEdge: Bool {
        self == .topRight || self == .right || self == .bottomRight
    }

    public var movesTopEdge: Bool {
        self == .topLeft || self == .top || self == .topRight
    }

    public var movesBottomEdge: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }
}

public enum Geometry {
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    public static func selectionRect(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect {
        let raw = normalizedRect(from: a, to: b).intersection(bounds)
        return raw.isNull ? .zero : raw
    }

    public static func clampedRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(max(0, rect.width), bounds.width)
        let height = min(max(0, rect.height), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func movedRect(_ rect: CGRect, by delta: CGPoint, in bounds: CGRect) -> CGRect {
        clampedRect(rect.offsetBy(dx: delta.x, dy: delta.y), to: bounds)
    }

    public static func handleRects(for rect: CGRect, size: CGFloat = 7) -> [ResizeHandle: CGRect] {
        let half = size / 2
        let midX = rect.midX
        let midY = rect.midY
        func square(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - half, y: y - half, width: size, height: size)
        }
        return [
            .topLeft: square(rect.minX, rect.minY),
            .top: square(midX, rect.minY),
            .topRight: square(rect.maxX, rect.minY),
            .right: square(rect.maxX, midY),
            .bottomRight: square(rect.maxX, rect.maxY),
            .bottom: square(midX, rect.maxY),
            .bottomLeft: square(rect.minX, rect.maxY),
            .left: square(rect.minX, midY),
        ]
    }

    public static func handleHit(at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 7) -> ResizeHandle? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        // 有序遍历：角热区优先于边，避免 tolerance 重叠时命中结果不确定
        let rects = handleRects(for: rect)
        let order: [ResizeHandle] = [
            .topLeft, .topRight, .bottomLeft, .bottomRight,
            .top, .bottom, .left, .right,
        ]
        for handle in order {
            guard let hitRect = rects[handle] else { continue }
            if hitRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return handle
            }
        }
        return nil
    }

    public static func resizedRect(
        _ rect: CGRect,
        handle: ResizeHandle,
        to point: CGPoint,
        in bounds: CGRect,
        minSize: CGFloat = 8
    ) -> CGRect {
        let p = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.movesLeftEdge { minX = p.x }
        if handle.movesRightEdge { maxX = p.x }
        if handle.movesTopEdge { minY = p.y }
        if handle.movesBottomEdge { maxY = p.y }

        if maxX - minX < minSize {
            if handle.movesLeftEdge {
                minX = maxX - minSize
            } else {
                maxX = minX + minSize
            }
        }
        if maxY - minY < minSize {
            if handle.movesTopEdge {
                minY = maxY - minSize
            } else {
                maxY = minY + minSize
            }
        }

        var width = max(minSize, maxX - minX)
        var height = max(minSize, maxY - minY)
        width = min(width, bounds.width)
        height = min(height, bounds.height)
        var x = minX
        var y = minY
        if x < bounds.minX { x = bounds.minX }
        if y < bounds.minY { y = bounds.minY }
        if x + width > bounds.maxX { x = bounds.maxX - width }
        if y + height > bounds.maxY { y = bounds.maxY - height }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func constrainedEnd(from start: CGPoint, to end: CGPoint, square: Bool, angleSnap: Bool, stepDegrees: CGFloat = 45) -> CGPoint {
        if square {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        if angleSnap {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return end }
            let step = stepDegrees * .pi / 180
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
        return end
    }

    public static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        if lengthSquared == 0 { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared))
        let projection = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    public static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            best = min(best, distance(from: point, toSegment: points[index - 1], points[index]))
        }
        return best
    }

    public static func pixelRect(for pointRect: CGRect, scale: CGFloat) -> CGRect {
        let x0 = (pointRect.minX * scale).rounded()
        let y0 = (pointRect.minY * scale).rounded()
        let x1 = (pointRect.maxX * scale).rounded()
        let y1 = (pointRect.maxY * scale).rounded()
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public static func pointRect(for pixelRect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return .zero }
        return CGRect(
            x: pixelRect.minX / scale,
            y: pixelRect.minY / scale,
            width: pixelRect.width / scale,
            height: pixelRect.height / scale
        )
    }

    public static func clampedPoint(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
