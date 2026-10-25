import AppKit
import CoreGraphics

public struct DetectedWindow {
    public let windowID: CGWindowID
    public let ownerName: String
    public let windowName: String?
    public let localRect: CGRect
    public let cocoaRect: CGRect

    public var title: String {
        let name = windowName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || name == ownerName {
            return ownerName
        }
        return "\(ownerName) — \(name)"
    }
}

public final class WindowDetector {
    private var cachedWindows: [[String: Any]] = []
    private var cacheDate = Date.distantPast
    private let cacheInterval: TimeInterval = 0.12

    public init() {}

    public func window(at localPoint: CGPoint, on screen: NSScreen, excludingPID: pid_t = getpid()) -> DetectedWindow? {
        let windows = windowList()
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }

        let cocoaPoint = CGPoint(
            x: screen.frame.minX + localPoint.x,
            y: screen.frame.maxY - localPoint.y
        )

        for info in windows {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != excludingPID else { continue }
            guard let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha > 0.03 else { continue }
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            guard cgBounds.width >= 24, cgBounds.height >= 24 else { continue }

            let cocoaRect = CGRect(
                x: cgBounds.minX,
                y: primaryHeight - cgBounds.maxY,
                width: cgBounds.width,
                height: cgBounds.height
            )
            guard cocoaRect.contains(cocoaPoint) else { continue }
            let clipped = cocoaRect.intersection(screen.frame)
            guard !clipped.isNull, clipped.width >= 12, clipped.height >= 12 else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner.isEmpty || owner == "Window Server" || owner == "Dock" || owner == "Control Center" {
                continue
            }
            let windowName = info[kCGWindowName as String] as? String
            let windowID = CGWindowID((info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            let localRect = CGRect(
                x: clipped.minX - screen.frame.minX,
                y: screen.frame.maxY - clipped.maxY,
                width: clipped.width,
                height: clipped.height
            )
            return DetectedWindow(
                windowID: windowID,
                ownerName: owner,
                windowName: windowName,
                localRect: localRect,
                cocoaRect: cocoaRect
            )
        }
        return nil
    }

    private func windowList() -> [[String: Any]] {
        let now = Date()
        if !cachedWindows.isEmpty, now.timeIntervalSince(cacheDate) < cacheInterval {
            return cachedWindows
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        cachedWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        cacheDate = now
        return cachedWindows
    }
}
