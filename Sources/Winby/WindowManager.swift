import Cocoa
import SwiftUI
import ScreenCaptureKit
import Vision

// MARK: - Window Manager

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var windows: [WindowInfo] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var sidebarResetTrigger: Bool = false  // Toggle to reset sidebar state

    let cid: Int32  // Internal for extensions
    private var refreshTimer: Timer?
    var isCycling = false  // When true, don't reorder windows during refresh
    var sidebarVisible = false  // When true, preserve window order during refresh

    /// Lock for thread-safe cache access
    let cacheLock = NSLock()  // Internal for extensions

    /// Cached thumbnails - kept even when windows go to background
    private var _thumbnailCache: [UInt32: NSImage] = [:]
    var thumbnailCache: [UInt32: NSImage] {
        get { cacheLock.withLock { _thumbnailCache } }
        set { cacheLock.withLock { _thumbnailCache = newValue } }
    }

    /// Cached full-size images for preview panel - captured alongside thumbnails
    private var _fullImageCache: [UInt32: NSImage] = [:]
    func getFullImage(for windowID: UInt32) -> NSImage? {
        cacheLock.withLock { _fullImageCache[windowID] }
    }
    func setFullImage(for windowID: UInt32, image: NSImage) {
        cacheLock.withLock { _fullImageCache[windowID] = image }
    }
    func clearFullImageCache() {
        cacheLock.withLock { _fullImageCache.removeAll() }
    }

    /// Tab screenshot cache - keyed by "pid:title" for background tabs
    /// When a tab is visible, we cache its screenshot here so we can show it when it's backgrounded
    var _tabScreenshotCache: [String: NSImage] = [:]  // Internal for extensions

    /// Flag to prevent concurrent background tab caching runs
    var _isCachingBackgroundTabs: Bool = false  // Internal for extensions

    /// Thread-safe tab screenshot cache access
    func getTabScreenshot(key: String) -> NSImage? {
        cacheLock.withLock { _tabScreenshotCache[key] }
    }

    func setTabScreenshot(key: String, image: NSImage) {
        cacheLock.withLock { _tabScreenshotCache[key] = image }
    }

    /// Tab OCR cache - keyed by "pid:title" for background tabs
    /// When a tab is visible, we cache its OCR text here for search when it's backgrounded
    private var _tabOcrCache: [String: String] = [:]

    /// Thread-safe tab OCR cache access
    func getTabOcr(key: String) -> String? {
        cacheLock.withLock { _tabOcrCache[key] }
    }

    func setTabOcr(key: String, text: String) {
        cacheLock.withLock { _tabOcrCache[key] = text }
    }

    /// Helper to generate tab cache key
    /// Uses pid and title only - tabIndex is unreliable between invocations
    func tabCacheKey(pid: pid_t, title: String) -> String {
        return "\(pid):\(title)"
    }

    /// Cached window content for search (windowID -> content snippet)
    private var _contentCache: [UInt32: String] = [:]
    var contentCache: [UInt32: String] {
        get { cacheLock.withLock { _contentCache } }
        set { cacheLock.withLock { _contentCache = newValue } }
    }

    /// Windows we've already tried and failed to get content from (don't retry)
    private var _contentFailed: Set<UInt32> = []
    var contentFailed: Set<UInt32> {
        get { cacheLock.withLock { _contentFailed } }
        set { cacheLock.withLock { _contentFailed = newValue } }
    }

    /// Screenshot hashes for change detection (windowID -> hash)
    private var _screenshotHashes: [UInt32: Int] = [:]
    var screenshotHashes: [UInt32: Int] {
        get { cacheLock.withLock { _screenshotHashes } }
        set { cacheLock.withLock { _screenshotHashes = newValue } }
    }

    /// Content search results (windowID -> match score)
    @Published var contentMatches: [UInt32: Int] = [:]

    /// Counter for generating synthetic window IDs for tabs without CGWindowID
    private var syntheticIDCounter: UInt32 = UInt32.max - 1_000_000

    /// Content indexing state (for extensions)
    var isIndexing = false
    var lastIndexed: [UInt32: Date] = [:]

    init() {
        cid = SLSMainConnectionID()
        refresh()

        // Refresh window list periodically
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // Apps to completely hide from the window list (system UI, etc.)
    private static let hiddenApps: Set<String> = [
        "Autofill",
        "AutoFillAgent",
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "Dock",
        "Spotlight",
        "Alfred",  // Alfred's window is usually just for search
        "AnySign",
        "universalAccessAuthWarn",
        "com.apple.WebKit.WebContent",
        "loginwindow",
    ]

    // Apps to show but NOT screenshot (sensitive content like password managers)
    private static let sensitiveAppNames: Set<String> = [
        "1Password",
        "Bitwarden",
        "Keychain Access",
        "Passwords",
    ]

    // Bundle IDs for sensitive apps (more reliable than names)
    private static let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",  // Older 1Password
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// Check if a window belongs to a sensitive app that should not be screenshotted
    func isSensitiveApp(pid: pid_t, appName: String) -> Bool {
        if Self.sensitiveAppNames.contains(appName) {
            return true
        }
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Self.sensitiveBundleIDs.contains(bundleID) {
            return true
        }
        return false
    }

    func refresh() {
        // Reset synthetic ID counter for this refresh cycle
        syntheticIDCounter = UInt32.max - 1_000_000

        // First: Get windows on the CURRENT space only (for accurate z-order and current-space detection)
        var currentSpaceWindowIDs = Set<UInt32>()
        var zOrder: [UInt32: Int] = [:]  // Lower = closer to front (from current space query)
        var zIndex = 0

        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for windowDict in windowList {
                guard let windowID = windowDict[kCGWindowNumber as String] as? UInt32,
                      let layer = windowDict[kCGWindowLayer as String] as? Int,
                      layer == 0
                else { continue }
                currentSpaceWindowIDs.insert(windowID)
                zOrder[windowID] = zIndex
                zIndex += 1
            }
        }
        debugLog("Current space has \(currentSpaceWindowIDs.count) windows (IDs: \(currentSpaceWindowIDs.sorted()))")

        // Second: Get ALL windows (including other spaces) for frame info
        var cgWindowInfo: [UInt32: (frame: CGRect, isOnScreen: Bool, title: String, pid: pid_t, appName: String)] = [:]

        if let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for windowDict in windowList {
                guard let windowID = windowDict[kCGWindowNumber as String] as? UInt32,
                      let boundsDict = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                      let layer = windowDict[kCGWindowLayer as String] as? Int,
                      let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                      layer == 0
                else { continue }

                let frame = CGRect(
                    x: boundsDict["X"] ?? 0,
                    y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0,
                    height: boundsDict["Height"] ?? 0
                )
                let isOnScreen = windowDict[kCGWindowIsOnscreen as String] as? Bool ?? false
                let title = windowDict[kCGWindowName as String] as? String ?? ""
                let appName = windowDict[kCGWindowOwnerName as String] as? String ?? "Unknown"
                cgWindowInfo[windowID] = (frame, isOnScreen, title, pid, appName)
            }
        }

        var newWindows: [WindowInfo] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Use AX API as source of truth for what windows exist
        // This correctly enumerates tabs in tabbed windows
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            if pid == myPID { continue }

            let appName = app.localizedName ?? "Unknown"
            if Self.hiddenApps.contains(appName) { continue }

            // Cache the app icon once per app (avoid repeated lookups)
            let appIcon = app.icon

            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                // Get CGWindowID for this AX window
                var windowID: UInt32 = 0
                guard _AXUIElementGetWindow(axWindow, &windowID) == .success else { continue }

                // Get title from AX (more reliable for tabs)
                var titleRef: CFTypeRef?
                var title = ""
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let axTitle = titleRef as? String {
                    title = axTitle
                }

                // Fall back to CG title if AX title is empty
                if title.isEmpty, let cgInfo = cgWindowInfo[windowID] {
                    title = cgInfo.title
                }

                // Skip windows without titles
                if title.isEmpty { continue }

                // Get frame - prefer CG info for accuracy
                var frame = CGRect.zero
                var isOnScreen = false
                if let cgInfo = cgWindowInfo[windowID] {
                    frame = cgInfo.frame
                    isOnScreen = cgInfo.isOnScreen
                } else {
                    // Fall back to AX position/size
                    var posRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
                       AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success {
                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                        frame = CGRect(origin: pos, size: size)
                        isOnScreen = true  // If AX can see it, assume it's on screen
                    }
                }

                // Skip tiny windows
                if frame.width < 100 || frame.height < 100 { continue }

                // Check for tabs in this window
                // Try browser-specific AppleScript first (Safari, Chrome, Arc)
                // Fall back to AX-based detection for other apps
                let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                let tabInfo: (titles: [String], selectedIndex: Int)
                if let browserTabs = getBrowserTabs(bundleId: bundleId, appName: appName) {
                    tabInfo = browserTabs
                } else {
                    tabInfo = getTabTitles(from: axWindow)
                }
                let tabTitles = tabInfo.titles

                // Determine if this window is on the current space
                let isOnCurrentSpace = currentSpaceWindowIDs.contains(windowID)

                // Debug: track space classification
                if !isOnCurrentSpace {
                    debugLog("Window \(windowID) '\(title)' from \(appName) NOT in currentSpaceWindowIDs (AX visible, CG not on-screen)")
                }

                if tabTitles.isEmpty {
                    // No tabs - just add the window
                    var windowInfo = WindowInfo(
                        windowID: windowID,
                        parentWindowID: nil,
                        pid: pid,
                        appName: appName,
                        title: title,
                        frame: frame,
                        isOnScreen: isOnScreen,
                        appIcon: appIcon
                    )
                    windowInfo.isOnCurrentSpace = isOnCurrentSpace
                    debugLog("AX add: \(appName) '\(title)' wid=\(windowID) onCurrentSpace=\(isOnCurrentSpace) onScreen=\(isOnScreen)")
                    newWindows.append(windowInfo)
                } else {
                    // Has tabs - add each tab
                    // Determine which tab is active:
                    // 1. Use AX selected index if available
                    // 2. Fall back to title matching
                    // 3. Default to first tab if neither works
                    var activeTabIndex = tabInfo.selectedIndex
                    if activeTabIndex < 0 {
                        // Try title matching as fallback
                        for (index, tabTitle) in tabTitles.enumerated() {
                            if tabTitle == title || title.contains(tabTitle) || tabTitle.contains(title) {
                                activeTabIndex = index
                                break
                            }
                        }
                    }
                    // If still unknown, use first tab as active
                    if activeTabIndex < 0 { activeTabIndex = 0 }

                    for (index, tabTitle) in tabTitles.enumerated() {
                        let isActiveTab = (index == activeTabIndex)

                        // For active tab, use the real window ID
                        // For other tabs, use stable synthetic IDs based on content
                        let finalWindowID: UInt32
                        if isActiveTab {
                            finalWindowID = windowID
                        } else {
                            // Generate stable synthetic ID from parent + title + index
                            // This ensures the same tab gets the same ID across refreshes
                            let stableKey = "\(windowID):\(tabTitle):\(index)"
                            var hasher = Hasher()
                            hasher.combine(stableKey)
                            let hash = hasher.finalize()
                            // Use high bits to avoid collision with real window IDs
                            finalWindowID = UInt32(truncatingIfNeeded: UInt(bitPattern: hash)) | 0x80000000
                        }

                        var windowInfo = WindowInfo(
                            windowID: finalWindowID,
                            parentWindowID: isActiveTab ? nil : windowID,  // Active tab is "main"
                            pid: pid,
                            appName: appName,
                            title: tabTitle,
                            frame: frame,
                            isOnScreen: isActiveTab,
                            appIcon: appIcon
                        )
                        windowInfo.isOnCurrentSpace = isOnCurrentSpace
                        windowInfo.tabIndex = index
                        debugLog("AX add tab: \(appName) '\(tabTitle)' wid=\(finalWindowID) parent=\(windowID) onCurrentSpace=\(isOnCurrentSpace) active=\(isActiveTab)")
                        newWindows.append(windowInfo)
                    }
                }
            }
        }

        debugLog("After AX enumeration: \(newWindows.count) windows")

        // Track which window IDs we've already added from AX enumeration
        // Include both windowID and parentWindowID to catch all real window IDs
        var axWindowIDs = Set(newWindows.map { $0.windowID })
        for window in newWindows {
            if let parentID = window.parentWindowID {
                axWindowIDs.insert(parentID)
            }
        }
        debugLog("axWindowIDs (including parents): \(axWindowIDs.sorted())")

        // Build list of windows by app for duplicate detection
        let axWindowsByApp = Dictionary(grouping: newWindows, by: { $0.appName })

        // Helper to normalize titles for comparison (strip terminal dimensions, handle ellipsis)
        func normalizeTitle(_ title: String) -> String {
            var t = title
            // Strip terminal dimensions like " — 124×36" at the end
            if let range = t.range(of: #" — \d+×\d+$"#, options: .regularExpression) {
                t.removeSubrange(range)
            }
            // Replace ellipsis with empty for prefix matching
            t = t.replacingOccurrences(of: "…", with: "")
            return t
        }

        // Add windows from OTHER spaces using CG info (AX can't see them)
        // These are windows in cgWindowInfo but NOT in currentSpaceWindowIDs and NOT already added
        for (windowID, cgInfo) in cgWindowInfo {
            // Skip if already added via AX (including as parent of a tab), or if on current space
            if axWindowIDs.contains(windowID) || currentSpaceWindowIDs.contains(windowID) {
                continue
            }

            // Skip windows without titles
            if cgInfo.title.isEmpty { continue }

            // Skip if we have an AX window from the same app with a matching title
            // This catches background tabs which have different CG window IDs
            if let axWindows = axWindowsByApp[cgInfo.appName] {
                let cgNorm = normalizeTitle(cgInfo.title)
                let isDuplicate = axWindows.contains { axWindow in
                    let axNorm = normalizeTitle(axWindow.title)
                    return axNorm == cgNorm ||
                           axNorm.contains(cgNorm) ||
                           cgNorm.contains(axNorm)
                }
                if isDuplicate {
                    debugLog("CG skip duplicate title: \(cgInfo.appName) '\(cgInfo.title)' wid=\(windowID)")
                    continue
                }
            }

            // Skip tiny windows
            if cgInfo.frame.width < 100 || cgInfo.frame.height < 100 { continue }

            // Skip phantom windows that don't belong to any space
            // Real windows belong to at least one space; orphaned/zombie windows have empty space list
            let windowArray = [windowID as CFNumber] as CFArray
            let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, windowArray) as? [CGSSpaceID] ?? []
            if spaces.isEmpty {
                debugLog("CG skip phantom window (no space): \(cgInfo.appName) '\(cgInfo.title)' wid=\(windowID)")
                continue
            }

            // Skip our own windows
            if cgInfo.pid == myPID { continue }

            // Skip excluded apps
            if Self.hiddenApps.contains(cgInfo.appName) { continue }

            // Get app icon for this PID
            let otherSpaceAppIcon = NSRunningApplication(processIdentifier: cgInfo.pid)?.icon

            var windowInfo = WindowInfo(
                windowID: windowID,
                parentWindowID: nil,
                pid: cgInfo.pid,
                appName: cgInfo.appName,
                title: cgInfo.title,
                frame: cgInfo.frame,
                isOnScreen: cgInfo.isOnScreen,
                appIcon: otherSpaceAppIcon
            )
            windowInfo.isOnCurrentSpace = false
            debugLog("CG add other-space: \(cgInfo.appName) '\(cgInfo.title)' wid=\(windowID)")
            newWindows.append(windowInfo)
        }

        debugLog("After CG enumeration: \(newWindows.count) windows total")

        // Sort by z-order (front to back), windows not in z-order map go to end
        // But if sidebar is visible, preserve the current order to avoid jumping
        if (isCycling || sidebarVisible) && !windows.isEmpty {
            // Preserve existing order - sort new windows by their position in current list
            // Use reduce to handle potential duplicate windowIDs (keep first occurrence)
            var currentOrder: [UInt32: Int] = [:]
            for (index, window) in windows.enumerated() {
                if currentOrder[window.windowID] == nil {
                    currentOrder[window.windowID] = index
                }
            }
            newWindows.sort { a, b in
                let aOrder = currentOrder[a.windowID] ?? Int.max
                let bOrder = currentOrder[b.windowID] ?? Int.max
                return aOrder < bOrder
            }
        } else {
            newWindows.sort { a, b in
                let aOrder = zOrder[a.windowID] ?? Int.max
                let bOrder = zOrder[b.windowID] ?? Int.max
                return aOrder < bOrder
            }
        }

        // Compute duplicate indices for windows with same title in same app
        var seenTitles: [String: Int] = [:]
        for i in 0..<newWindows.count {
            let key = "\(newWindows[i].pid):\(newWindows[i].title)"
            let count = seenTitles[key] ?? 0
            newWindows[i].duplicateIndex = count
            seenTitles[key] = count + 1
        }

        // Cluster tabs: group windows from same app with same frame
        // The frontmost tab stays in z-order position, others cluster after it
        newWindows = clusterTabs(newWindows)

        DispatchQueue.main.async {
            self.windows = newWindows
            // Index content in background for instant search
            self.indexContentInBackground()
        }
    }

    /// Cluster tabs together: tabs with same parentWindowID are grouped
    /// The frontmost tab (by z-order) stays in place, others follow immediately after
    private func clusterTabs(_ windows: [WindowInfo]) -> [WindowInfo] {
        // Build a map of parent window ID -> indices of child tabs
        // Also track which windows are parents (have tabs pointing to them)
        var tabsByParent: [UInt32: [Int]] = [:]
        var parentIndices: [UInt32: Int] = [:]

        for (index, window) in windows.enumerated() {
            if let parentID = window.parentWindowID {
                // This is a tab - group by parent
                tabsByParent[parentID, default: []].append(index)
            } else {
                // This might be a parent window
                parentIndices[window.windowID] = index
            }
        }

        // If no tabs, return as-is
        if tabsByParent.isEmpty {
            return windows
        }

        // Build the clustered list
        var result: [WindowInfo] = []
        var consumed: Set<Int> = []

        for (index, window) in windows.enumerated() {
            if consumed.contains(index) {
                continue
            }

            result.append(window)
            consumed.insert(index)

            // If this window has tabs, add them right after (indented)
            if let tabIndices = tabsByParent[window.windowID] {
                for tabIndex in tabIndices {
                    if !consumed.contains(tabIndex) {
                        var clusteredWindow = windows[tabIndex]
                        clusteredWindow.isClusteredTab = true
                        result.append(clusteredWindow)
                        consumed.insert(tabIndex)
                    }
                }
            }
        }

        return result
    }

    /// Capture a window image using CGSHWCaptureWindowList private API
    /// This can capture minimized windows and windows on other spaces that ScreenCaptureKit cannot
}
