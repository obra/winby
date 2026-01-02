import Cocoa
import ScreenCaptureKit

// MARK: - Screenshot Capture

extension WindowManager {
    func captureWindowViaPrivateAPI(windowID: UInt32, fullSize: Bool = false) -> CGImage? {
        var wid = CGWindowID(windowID)
        let options: CGSWindowCaptureOptions = fullSize
            ? [.ignoreGlobalClipShape, .bestResolution, .fullSize]
            : [.ignoreGlobalClipShape, .bestResolution]

        // Match AltTab's exact calling pattern
        let result = CGSHWCaptureWindowList(CGSMainConnectionID(), &wid, 1, options)
        let images = result.takeRetainedValue() as? [CGImage] ?? []

        guard let image = images.first else {
            debugLog("CGSHWCaptureWindowList failed for window \(windowID)")
            return nil
        }

        return image
    }

    /// Generate a placeholder image that looks like a macOS window
    /// Used when we can't capture a real screenshot (background tabs, etc.)
    func generatePlaceholderWindow(title: String, appIcon: NSImage?, size: CGSize) -> NSImage {
        let titleBarHeight: CGFloat = 28
        let trafficLightSize: CGFloat = 12
        let trafficLightSpacing: CGFloat = 8
        let trafficLightLeftPadding: CGFloat = 14
        let cornerRadius: CGFloat = 10

        let image = NSImage(size: size)
        image.lockFocus()

        // Window background (dark mode style)
        let windowPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.15, alpha: 1.0).setFill()
        windowPath.fill()

        // Title bar background (slightly lighter)
        let titleBarPath = NSBezierPath()
        titleBarPath.move(to: NSPoint(x: 0, y: size.height - titleBarHeight))
        titleBarPath.line(to: NSPoint(x: 0, y: size.height - cornerRadius))
        titleBarPath.appendArc(withCenter: NSPoint(x: cornerRadius, y: size.height - cornerRadius),
                               radius: cornerRadius, startAngle: 180, endAngle: 90, clockwise: true)
        titleBarPath.line(to: NSPoint(x: size.width - cornerRadius, y: size.height))
        titleBarPath.appendArc(withCenter: NSPoint(x: size.width - cornerRadius, y: size.height - cornerRadius),
                               radius: cornerRadius, startAngle: 90, endAngle: 0, clockwise: true)
        titleBarPath.line(to: NSPoint(x: size.width, y: size.height - titleBarHeight))
        titleBarPath.close()
        NSColor(white: 0.22, alpha: 1.0).setFill()
        titleBarPath.fill()

        // Traffic lights
        let trafficLightY = size.height - titleBarHeight / 2 - trafficLightSize / 2
        let colors: [NSColor] = [
            NSColor(red: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),  // Close (red)
            NSColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 1.0),  // Minimize (yellow)
            NSColor(red: 0.3, green: 0.8, blue: 0.35, alpha: 1.0)    // Zoom (green)
        ]
        for (index, color) in colors.enumerated() {
            let x = trafficLightLeftPadding + CGFloat(index) * (trafficLightSize + trafficLightSpacing)
            let circleRect = NSRect(x: x, y: trafficLightY, width: trafficLightSize, height: trafficLightSize)
            let circle = NSBezierPath(ovalIn: circleRect)
            color.setFill()
            circle.fill()
        }

        // Title text (centered in title bar, avoiding traffic lights)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor(white: 0.9, alpha: 1.0)
        ]
        let titleString = NSAttributedString(string: title, attributes: titleAttributes)
        let titleSize = titleString.size()
        let titleX = max(trafficLightLeftPadding + 3 * (trafficLightSize + trafficLightSpacing) + 10,
                         (size.width - titleSize.width) / 2)
        let titleY = size.height - titleBarHeight / 2 - titleSize.height / 2
        let availableWidth = size.width - titleX - 10
        if availableWidth > 50 {
            let drawRect = NSRect(x: titleX, y: titleY, width: min(titleSize.width, availableWidth), height: titleSize.height)
            titleString.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        // App icon centered in content area
        if let icon = appIcon {
            let contentHeight = size.height - titleBarHeight
            let iconSize = min(contentHeight * 0.5, size.width * 0.4, 128)
            let iconX = (size.width - iconSize) / 2
            let iconY = (contentHeight - iconSize) / 2
            let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.8)
        }

        // Subtle border
        let borderPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.3, alpha: 1.0).setStroke()
        borderPath.lineWidth = 1
        borderPath.stroke()

        image.unlockFocus()
        return image
    }

    func thumbnail(for windowID: UInt32, maxSize: CGSize = CGSize(width: 200, height: 150)) async -> NSImage? {
        debugLog("thumbnail: starting for window \(windowID)")

        // Get window info
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            // Return cached if window no longer exists
            debugLog("thumbnail: window \(windowID) not found, returning cache")
            return thumbnailCache[windowID]
        }

        // For sensitive apps (password managers), generate a placeholder instead of real screenshot
        if isSensitiveApp(pid: window.pid, appName: window.appName) {
            debugLog("thumbnail: sensitive app '\(window.appName)', generating placeholder")
            let appIcon = NSRunningApplication(processIdentifier: window.pid)?.icon
            let aspectRatio = window.frame.width / window.frame.height
            let placeholderSize: CGSize
            if aspectRatio > maxSize.width / maxSize.height {
                placeholderSize = CGSize(width: maxSize.width, height: maxSize.width / aspectRatio)
            } else {
                placeholderSize = CGSize(width: maxSize.height * aspectRatio, height: maxSize.height)
            }
            return generatePlaceholderWindow(title: window.title, appIcon: appIcon, size: placeholderSize)
        }

        // For background tabs, check tab screenshot cache first
        if window.parentWindowID != nil {
            let cacheKey = tabCacheKey(pid: window.pid, title: window.title)
            debugLog("thumbnail: background tab '\(window.title)' cacheKey='\(cacheKey)'")
            if let cached = getTabScreenshot(key: cacheKey) {
                debugLog("thumbnail: cache HIT for '\(cacheKey)'")
                return cached
            }
            debugLog("thumbnail: cache MISS for '\(cacheKey)' (have \(cacheLock.withLock { _tabScreenshotCache.count }) cached)")
            // Background tabs can't be captured directly - generate placeholder window
            let appIcon = NSRunningApplication(processIdentifier: window.pid)?.icon
            // Use parent window's frame (tabs have same size as parent)
            let parentFrame = windows.first(where: { $0.windowID == window.parentWindowID })?.frame ?? window.frame
            // Scale to fit maxSize while preserving aspect ratio
            let aspectRatio = parentFrame.width / parentFrame.height
            let placeholderSize: CGSize
            if aspectRatio > maxSize.width / maxSize.height {
                // Window is wider - constrain by width
                placeholderSize = CGSize(width: maxSize.width, height: maxSize.width / aspectRatio)
            } else {
                // Window is taller - constrain by height
                placeholderSize = CGSize(width: maxSize.height * aspectRatio, height: maxSize.height)
            }
            let placeholder = generatePlaceholderWindow(title: window.title, appIcon: appIcon, size: placeholderSize)
            return placeholder
        }

        // Try ScreenCaptureKit for visible windows
        debugLog("thumbnail: trying ScreenCaptureKit for window \(windowID)")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
                debugLog("thumbnail: found scWindow for \(windowID)")
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                // Capture at higher resolution for quality
                config.width = Int(maxSize.width * 2)
                config.height = Int(maxSize.height * 2)
                config.scalesToFit = true
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImage = NSImage(cgImage: image, size: maxSize)
                thumbnailCache[windowID] = nsImage

                // Cache full resolution version for background tab use
                let cacheKey = tabCacheKey(pid: window.pid, title: window.title)
                debugLog("thumbnail: caching screenshot for '\(window.title)' cacheKey='\(cacheKey)'")
                let fullResConfig = SCStreamConfiguration()
                fullResConfig.width = Int(scWindow.frame.width * 2)  // Retina
                fullResConfig.height = Int(scWindow.frame.height * 2)
                fullResConfig.scalesToFit = false
                fullResConfig.showsCursor = false
                if let fullResImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: fullResConfig) {
                    let fullResNsImage = NSImage(cgImage: fullResImage, size: scWindow.frame.size)
                    setTabScreenshot(key: cacheKey, image: fullResNsImage)
                    debugLog("thumbnail: cached screenshot for '\(cacheKey)' (now have \(cacheLock.withLock { _tabScreenshotCache.count }) cached)")
                }

                return nsImage
            }
        } catch {
            // ScreenCaptureKit failed - try private API fallback
            debugLog("ScreenCaptureKit failed for window \(windowID), trying private API")
        }

        // Fallback: try private API (works for minimized/other-space windows)
        if let cgImage = captureWindowViaPrivateAPI(windowID: windowID, fullSize: false) {
            debugLog("Private API captured window \(windowID): \(cgImage.width)x\(cgImage.height)")
            let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            let nsImage = NSImage(cgImage: cgImage, size: size)

            // Scale down to maxSize
            let scale = min(maxSize.width / size.width, maxSize.height / size.height)
            let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
            let scaledImage = NSImage(size: scaledSize)
            scaledImage.lockFocus()
            nsImage.draw(in: NSRect(origin: .zero, size: scaledSize))
            scaledImage.unlockFocus()

            return scaledImage
        }

        // Final fallback: use app icon
        if let app = NSRunningApplication(processIdentifier: window.pid),
           let icon = app.icon {
            return icon
        }

        return nil
    }

}
