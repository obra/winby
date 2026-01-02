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

    // Apps to exclude from the window list
    private static let excludedApps: Set<String> = [
        "Autofill",
        "AutoFillAgent",
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "Dock",
        "Spotlight",
        "Alfred",  // Alfred's window is usually just for search
        "1Password",
        "Bitwarden",
        "Keychain Access",
        "AnySign",
        "universalAccessAuthWarn",
        "com.apple.WebKit.WebContent",
        "loginwindow",
    ]

    /// Debug: dump AX hierarchy to find tab structure
    private func dumpAXHierarchy(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 3) {
        guard depth < maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)

        var roleRef: CFTypeRef?
        var role = "unknown"
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success {
            role = roleRef as? String ?? "unknown"
        }

        var titleRef: CFTypeRef?
        var title = ""
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success {
            title = titleRef as? String ?? ""
        }

        var descRef: CFTypeRef?
        var desc = ""
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success {
            desc = descRef as? String ?? ""
        }

        debugLog("\(indent)[\(role)] title='\(title)' desc='\(desc)'")

        // Get children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                dumpAXHierarchy(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    /// Get tab titles from a window's tab group
    /// Returns (tab titles, index of selected tab) - selectedIndex is -1 if unknown
    private func getTabTitles(from window: AXUIElement) -> (titles: [String], selectedIndex: Int) {
        var tabs: [String] = []
        var selectedIndex: Int = -1

        // Look for AXTabGroup in children
        func findTabs(in element: AXUIElement, depth: Int = 0) {
            guard depth < 5 else { return }

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {

                // Found a tab group - get its tabs
                if role == "AXTabGroup" {
                    // First try kAXTabsAttribute (standard tabs)
                    var tabsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXTabsAttribute as CFString, &tabsRef) == .success,
                       let tabElements = tabsRef as? [AXUIElement] {
                        for (index, tab) in tabElements.enumerated() {
                            var titleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef) == .success,
                               let title = titleRef as? String, !title.isEmpty {
                                tabs.append(title)

                                // Check if this tab is selected (via value attribute = 1)
                                var valueRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &valueRef) == .success,
                                   let value = valueRef as? Int, value == 1 {
                                    selectedIndex = index
                                }
                            }
                        }
                    }
                    // If no tabs found, check for radio buttons (Terminal.app uses this)
                    if tabs.isEmpty {
                        var childrenRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                           let children = childrenRef as? [AXUIElement] {
                            for (index, child) in children.enumerated() {
                                var childRoleRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRoleRef) == .success,
                                   let childRole = childRoleRef as? String,
                                   childRole == "AXRadioButton" {
                                    var titleRef: CFTypeRef?
                                    if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                                       let title = titleRef as? String, !title.isEmpty {
                                        tabs.append(title)

                                        // Check if selected
                                        var valueRef: CFTypeRef?
                                        if AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef) == .success,
                                           let value = valueRef as? Int, value == 1 {
                                            selectedIndex = index
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }

                // Also check for radio groups (sometimes used for tabs)
                if role == "AXRadioGroup" {
                    var childrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                       let children = childrenRef as? [AXUIElement] {
                        for (index, child) in children.enumerated() {
                            var childRoleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRoleRef) == .success,
                               let childRole = childRoleRef as? String,
                               childRole == "AXRadioButton" {
                                var titleRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                                   let title = titleRef as? String, !title.isEmpty {
                                    tabs.append(title)

                                    // Check if this radio button is selected
                                    var valueRef: CFTypeRef?
                                    if AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef) == .success,
                                       let value = valueRef as? Int, value == 1 {
                                        selectedIndex = index
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            }

            // Recurse into children
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    findTabs(in: child, depth: depth + 1)
                }
            }
        }

        findTabs(in: window)
        return (tabs, selectedIndex)
    }

    /// Get browser tabs via AppleScript (Safari, Chrome, Arc have native scripting support)
    /// Returns (tabTitles, selectedIndex) or nil if not a supported browser
    private func getBrowserTabs(bundleId: String, appName: String) -> (titles: [String], selectedIndex: Int)? {
        var script: String?

        if bundleId == "com.apple.Safari" || appName == "Safari" {
            script = """
            tell application "Safari"
                set tabInfo to {}
                set selectedIdx to -1
                repeat with w in windows
                    set tabCount to count of tabs of w
                    set currentTab to current tab of w
                    repeat with i from 1 to tabCount
                        set t to tab i of w
                        set tabName to name of t
                        set end of tabInfo to tabName
                        if t is currentTab then
                            set selectedIdx to (i - 1)
                        end if
                    end repeat
                    -- Only process first window
                    exit repeat
                end repeat
                return {tabInfo, selectedIdx}
            end tell
            """
        } else if bundleId == "com.google.Chrome" || appName.contains("Chrome") {
            script = """
            tell application "Google Chrome"
                set tabInfo to {}
                set selectedIdx to -1
                repeat with w in windows
                    set tabCount to count of tabs of w
                    set activeIdx to active tab index of w
                    repeat with i from 1 to tabCount
                        set tabTitle to title of tab i of w
                        set end of tabInfo to tabTitle
                    end repeat
                    set selectedIdx to (activeIdx - 1)
                    exit repeat
                end repeat
                return {tabInfo, selectedIdx}
            end tell
            """
        }

        guard let scriptSource = script else { return nil }

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: scriptSource) else { return nil }

        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }

        // Parse result - it's a list containing {tabTitles, selectedIndex}
        guard result.numberOfItems >= 2 else { return nil }

        let tabListDesc = result.atIndex(1)
        let selectedIdxDesc = result.atIndex(2)

        var titles: [String] = []
        if let tabList = tabListDesc {
            for i in 1...tabList.numberOfItems {
                if let item = tabList.atIndex(i), let title = item.stringValue {
                    titles.append(title)
                }
            }
        }

        let selectedIdx = selectedIdxDesc?.int32Value ?? -1
        return (titles, Int(selectedIdx))
    }

    /// Enable accessibility for Electron/Chrome apps that require it
    private func enableAppAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        // Enable for Electron apps
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
        // Enable for Chrome-based apps
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    }

    /// Try to get text from an element using multiple attribute approaches
    private func getTextFromElement(_ element: AXUIElement) -> String? {
        // Try AXValue first (most common)
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let text = valueRef as? String, !text.isEmpty {
            return text
        }

        // Try AXTitle
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let text = titleRef as? String, !text.isEmpty {
            return text
        }

        // Try AXDescription
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let text = descRef as? String, !text.isEmpty {
            return text
        }

        // Try AXHelp
        var helpRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXHelp" as CFString, &helpRef) == .success,
           let text = helpRef as? String, !text.isEmpty {
            return text
        }

        // Try AXStringForRange (parameterized attribute for text areas)
        var numCharsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXNumberOfCharacters" as CFString, &numCharsRef) == .success,
           let numChars = numCharsRef as? Int, numChars > 0 {
            // Create range for all characters
            var range = CFRange(location: 0, length: min(numChars, 5000))
            let rangeValue: AXValue? = AXValueCreate(.cfRange, &range)
            if let rangeValue = rangeValue {
                var stringRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, rangeValue, &stringRef) == .success,
                   let text = stringRef as? String, !text.isEmpty {
                    return text
                }
            }
        }

        return nil
    }

    /// Get text content from a window (searches for AXTextArea, AXStaticText, AXWebArea, etc.)
    /// Returns up to maxChars of content for search purposes
    func getWindowContent(windowID: UInt32, pid: pid_t, maxChars: Int = 5000) -> String? {
        // First, enable accessibility for Electron/Chrome apps
        enableAppAccessibility(pid: pid)

        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        for axWindow in axWindows {
            var axWindowID: UInt32 = 0
            guard _AXUIElementGetWindow(axWindow, &axWindowID) == .success,
                  axWindowID == windowID else { continue }

            // Search for text content in the window hierarchy
            var content = ""
            var visitedTexts = Set<String>()  // Avoid duplicates
            var elementsVisited = 0
            let maxElements = 500  // Limit to prevent beachball on huge trees

            func findText(in element: AXUIElement, depth: Int = 0) {
                elementsVisited += 1
                guard depth < 20, content.count < maxChars, elementsVisited < maxElements else { return }

                var roleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? ""

                // Roles that typically contain text content
                let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText", "AXText",
                                 "AXLink", "AXCell", "AXHeading", "AXParagraph"]

                // UI chrome roles - skip entirely (don't extract text or recurse)
                let chromeRoles: Set<String> = ["AXButton", "AXMenuItem", "AXTab", "AXRadioButton",
                                   "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXToolbar",
                                   "AXMenuBar", "AXMenu", "AXSlider", "AXIncrementor",
                                   "AXImage", "AXColorWell", "AXComboBox"]

                // Skip chrome roles entirely
                if chromeRoles.contains(role) {
                    return
                }

                // For terminals/text areas, try to get the VALUE which has all text
                // Use AXStringForRange to get just the visible/recent portion
                if role == "AXTextArea" || role == "AXTextField" {
                    // Try to get visible text range first (for terminals, this is what's on screen)
                    var visibleRangeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, "AXVisibleCharacterRange" as CFString, &visibleRangeRef) == .success,
                       let rangeValue = visibleRangeRef {
                        var visibleRange = CFRange()
                        if AXValueGetValue(rangeValue as! AXValue, .cfRange, &visibleRange) {
                            // Get the visible text
                            var rangeForQuery = visibleRange
                            if let queryRange = AXValueCreate(.cfRange, &rangeForQuery) {
                                var textRef: CFTypeRef?
                                if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, queryRange, &textRef) == .success,
                                   let text = textRef as? String, !text.isEmpty {
                                    if !content.isEmpty { content += " " }
                                    content += String(text.suffix(maxChars - content.count))  // Take END for terminals
                                    return
                                }
                            }
                        }
                    }
                }

                // Extract text from content roles
                if textRoles.contains(role) {
                    if let text = getTextFromElement(element), !text.isEmpty {
                        let trimmed = String(text.prefix(500))
                        if !visitedTexts.contains(trimmed) && text.count > 2 {
                            visitedTexts.insert(trimmed)
                            if !content.isEmpty { content += " " }
                            content += String(text.prefix(maxChars - content.count))
                        }
                    }
                }

                // Prefer AXVisibleChildren (what's actually on screen) over AXChildren
                var visibleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXVisibleChildren" as CFString, &visibleRef) == .success,
                   let visible = visibleRef as? [AXUIElement], !visible.isEmpty {
                    for child in visible {
                        findText(in: child, depth: depth + 1)
                        if content.count >= maxChars || elementsVisited >= maxElements { break }
                    }
                } else {
                    // Fall back to all children
                    var childrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                       let children = childrenRef as? [AXUIElement] {
                        for child in children {
                            findText(in: child, depth: depth + 1)
                            if content.count >= maxChars || elementsVisited >= maxElements { break }
                        }
                    }
                }
            }

            findText(in: axWindow)
            debugLog("AX: visited \(elementsVisited) elements, got \(content.count) chars from window \(windowID)")
            return content.isEmpty ? nil : content
        }
        return nil
    }

    /// Compute a quick hash of an image by sampling pixels (for change detection)

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
            if Self.excludedApps.contains(appName) { continue }

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
            if Self.excludedApps.contains(cgInfo.appName) { continue }

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
