import Cocoa

// MARK: - Focus and Tab Selection

extension WindowManager {
    func bringToFront(_ windowID: UInt32) {
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            debugLog("Window \(windowID) not found in list")
            return
        }

        debugLog("Bringing to front: window \(windowID) '\(window.title)' from \(window.appName)")

        // Use the proper private APIs to focus this window
        focusWindow(windowID)

        // Also ensure the app is activated and window gets keyboard focus
        bringAppToFront(pid: window.pid)
    }

    /// Toggle fullscreen for a window using Accessibility API
    func toggleFullscreen(_ windowID: UInt32) {
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            debugLog("Fullscreen: Window \(windowID) not found")
            return
        }

        debugLog("Toggling fullscreen for window \(windowID) '\(window.title)'")

        let appElement = AXUIElementCreateApplication(window.pid)

        // Get windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            debugLog("Fullscreen: Could not get AX windows")
            return
        }

        // Find the window by matching title or just use first window
        var targetWindow: AXUIElement?
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               title == window.title {
                targetWindow = axWindow
                break
            }
        }

        // Fall back to first window if no match
        if targetWindow == nil {
            targetWindow = axWindows.first
        }

        guard let axWindow = targetWindow else {
            debugLog("Fullscreen: No target window found")
            return
        }

        // Get the fullscreen button and press it
        var buttonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXFullScreenButtonAttribute as CFString, &buttonRef) == .success,
           let button = buttonRef as! AXUIElement? {
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            debugLog("Fullscreen button press result: \(result == .success ? "success" : "failed")")
        } else {
            debugLog("Fullscreen: Could not get fullscreen button")
        }
    }

    /// Direct AX-based tab switching - clicks tab radio buttons directly via Accessibility API
    /// Returns true if successful
    private func selectTabViaAX(pid: pid_t, tabIndex: Int, tabTitle: String? = nil) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        // Get windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement],
              let window = axWindows.first else {
            print("[Winby] AX tab switch: no windows found")
            return false
        }

        // Find tab group recursively
        func findTabGroup(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 6 else { return nil }

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXTabGroup" {
                return element
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if let found = findTabGroup(in: child, depth: depth + 1) {
                        return found
                    }
                }
            }
            return nil
        }

        guard let tabGroup = findTabGroup(in: window) else {
            print("[Winby] AX tab switch: no tab group found")
            return false
        }

        // Get children (radio buttons) of tab group
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            print("[Winby] AX tab switch: no children in tab group")
            return false
        }

        // Filter to radio buttons only and collect with titles
        var radioButtons: [(element: AXUIElement, title: String)] = []
        for child in children {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXRadioButton" {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""
                radioButtons.append((child, title))
            }
        }

        // Find target tab - prefer title match, fall back to index
        var targetTab: AXUIElement?
        var matchedTitle = ""

        if let tabTitle = tabTitle {
            // Try exact match first
            for (element, title) in radioButtons {
                if title == tabTitle {
                    targetTab = element
                    matchedTitle = title
                    break
                }
            }
            // Try contains match if no exact match
            if targetTab == nil {
                for (element, title) in radioButtons {
                    if title.contains(tabTitle) || tabTitle.contains(title) {
                        targetTab = element
                        matchedTitle = title
                        break
                    }
                }
            }
        }

        // Fall back to index if title match failed
        if targetTab == nil && tabIndex < radioButtons.count {
            targetTab = radioButtons[tabIndex].element
            matchedTitle = radioButtons[tabIndex].title
        }

        guard let tab = targetTab else {
            print("[Winby] AX tab switch: could not find tab '\(tabTitle ?? "index \(tabIndex)")' (have \(radioButtons.count) tabs: \(radioButtons.map { $0.title }))")
            return false
        }

        // Click it
        let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        print("[Winby] AX tab switch: clicked '\(matchedTitle)' - result: \(result.rawValue)")
        return result == .success
    }

    /// Try to select a tab using AppleScript (more reliable for Terminal, Safari, etc.)
    /// Returns true if AppleScript worked, false if we need to fall back to AX
    private func selectTabViaAppleScript(appName: String, pid: pid_t, tabTitle: String, tabIndex: Int) -> Bool {
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""

        // For Terminal.app and Ghostty, use direct AX approach (AppleScript doesn't work reliably from Swift)
        if bundleId == "com.apple.Terminal" || bundleId == "com.mitchellh.ghostty" {
            print("[Winby] \(appName) detected, using direct AX tab switch for '\(tabTitle)'")
            return selectTabViaAX(pid: pid, tabIndex: tabIndex, tabTitle: tabTitle)
        }

        let escapedTitle = tabTitle.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"")
        let targetIndex = tabIndex + 1  // AppleScript is 1-indexed

        var script: String

        // Use native AppleScript for browsers (they have proper scripting support)
        if bundleId == "com.apple.Safari" || appName == "Safari" {
            print("[Winby] Safari tab switch: '\(tabTitle)' at index \(targetIndex)")
            script = """
            tell application "Safari"
                repeat with w in windows
                    set tabCount to count of tabs of w
                    -- Try by index first
                    if \(targetIndex) ≤ tabCount then
                        set t to tab \(targetIndex) of w
                        set current tab of w to t
                        return "clicked by index: " & (name of t)
                    end if
                    -- Fall back to title match
                    repeat with i from 1 to tabCount
                        set t to tab i of w
                        if name of t contains "\(escapedTitle)" then
                            set current tab of w to t
                            return "clicked by title: " & (name of t)
                        end if
                    end repeat
                    exit repeat
                end repeat
                return "not found"
            end tell
            """
        } else if bundleId == "com.google.Chrome" || appName.contains("Chrome") {
            print("[Winby] Chrome tab switch: '\(tabTitle)' at index \(targetIndex)")
            script = """
            tell application "Google Chrome"
                repeat with w in windows
                    set tabCount to count of tabs of w
                    -- Try by index first
                    if \(targetIndex) ≤ tabCount then
                        set active tab index of w to \(targetIndex)
                        return "clicked by index: " & (title of tab \(targetIndex) of w)
                    end if
                    -- Fall back to title match
                    repeat with i from 1 to tabCount
                        if title of tab i of w contains "\(escapedTitle)" then
                            set active tab index of w to i
                            return "clicked by title: " & (title of tab i of w)
                        end if
                    end repeat
                    exit repeat
                end repeat
                return "not found"
            end tell
            """
        } else {
            // For native apps (Terminal, Ghostty, etc), use System Events
            let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
            print("[Winby] System Events tab switch for \(appName): '\(tabTitle)' at index \(targetIndex)")
            script = """
            tell application "System Events"
                tell process "\(escapedAppName)"
                    tell window 1
                        try
                            set tg to tab group 1
                            set tabButtons to every radio button of tg
                            set tabCount to count of tabButtons

                            -- Click by index directly (handles duplicate titles)
                            if \(targetIndex) ≤ tabCount then
                                set t to radio button \(targetIndex) of tg
                                click t
                                return "clicked"
                            end if

                            return "index \(targetIndex) out of range, only " & tabCount & " tabs"
                        on error errMsg
                            return "error: " & errMsg
                        end try
                    end tell
                end tell
            end tell
            """
        }

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[Winby] AppleScript error: \(error)")
                return false
            }
            let resultStr = result.stringValue ?? "unknown"
            print("[Winby] AppleScript result: \(resultStr)")
            return resultStr.contains("clicked")
        }

        return false
    }

    /// Cache screenshots for all background tabs by temporarily switching to each tab
    /// This is called after the sidebar is dismissed when cacheBackgroundTabs is enabled
    func cacheBackgroundTabScreenshots() async {
        // Both settings must be enabled for caching to run
        guard AppConfig.shared.cacheBackgroundTabs && AppConfig.shared.showBackgroundTabs else { return }

        // Only run when Winby is in the background (not active)
        let isActive = await MainActor.run { NSApp.isActive }
        guard !isActive else {
            debugLog("cacheBackgroundTabs: Winby is active, skipping")
            return
        }

        // Prevent concurrent runs
        guard !_isCachingBackgroundTabs else {
            debugLog("cacheBackgroundTabs: already running, skipping")
            return
        }
        _isCachingBackgroundTabs = true
        defer { _isCachingBackgroundTabs = false }

        debugLog("cacheBackgroundTabs: starting background tab caching")

        // Group background tabs by their parent window
        var tabsByParent: [UInt32: [(window: WindowInfo, index: Int)]] = [:]
        for window in windows {
            if let parentID = window.parentWindowID {
                let cacheKey = tabCacheKey(pid: window.pid, title: window.title)
                // Skip if already cached
                if getTabScreenshot(key: cacheKey) != nil {
                    debugLog("cacheBackgroundTabs: already cached '\(window.title)'")
                    continue
                }
                tabsByParent[parentID, default: []].append((window, window.tabIndex))
            }
        }

        if tabsByParent.isEmpty {
            debugLog("cacheBackgroundTabs: no uncached background tabs found")
            return
        }

        debugLog("cacheBackgroundTabs: found \(tabsByParent.values.flatMap { $0 }.count) uncached tabs in \(tabsByParent.count) windows")

        // Process each parent window's tabs
        for (parentID, tabs) in tabsByParent {
            guard let parentWindow = windows.first(where: { $0.windowID == parentID }) else {
                debugLog("cacheBackgroundTabs: parent window \(parentID) not found")
                continue
            }

            let appName = parentWindow.appName
            let pid = parentWindow.pid
            let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""

            debugLog("cacheBackgroundTabs: processing \(tabs.count) tabs for \(appName)")

            // Find the currently active tab (the one that matches the parent window title)
            let originalActiveIndex = tabs.first { $0.window.title == parentWindow.title }?.index ?? 0

            // Sort tabs by index for consistent processing order
            let sortedTabs = tabs.sorted { $0.index < $1.index }

            // Iterate through each background tab
            for (tabWindow, tabIndex) in sortedTabs {
                debugLog("cacheBackgroundTabs: switching to tab \(tabIndex) '\(tabWindow.title)'")

                // Switch to the tab
                let switched: Bool
                if bundleId == "com.apple.Safari" || bundleId == "com.google.Chrome" || bundleId.contains("Chrome") {
                    switched = selectTabViaAppleScript(appName: appName, pid: pid, tabTitle: tabWindow.title, tabIndex: tabIndex)
                } else {
                    switched = selectTabViaAX(pid: pid, tabIndex: tabIndex, tabTitle: tabWindow.title)
                }

                if !switched {
                    debugLog("cacheBackgroundTabs: failed to switch to tab '\(tabWindow.title)'")
                    continue
                }

                // Wait for the tab to render (250ms seems to work well)
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms

                // Capture the screenshot using the parent window ID (now showing this tab)
                if let cgImage = captureWindowViaPrivateAPI(windowID: parentID, fullSize: true) {
                    let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                    let nsImage = NSImage(cgImage: cgImage, size: size)
                    let cacheKey = tabCacheKey(pid: pid, title: tabWindow.title)
                    setTabScreenshot(key: cacheKey, image: nsImage)
                    debugLog("cacheBackgroundTabs: cached screenshot for '\(tabWindow.title)'")
                } else {
                    debugLog("cacheBackgroundTabs: failed to capture '\(tabWindow.title)'")
                }
            }

            // Restore the original active tab
            debugLog("cacheBackgroundTabs: restoring original tab index \(originalActiveIndex)")
            if bundleId == "com.apple.Safari" || bundleId == "com.google.Chrome" || bundleId.contains("Chrome") {
                _ = selectTabViaAppleScript(appName: appName, pid: pid, tabTitle: parentWindow.title, tabIndex: originalActiveIndex)
            } else {
                _ = selectTabViaAX(pid: pid, tabIndex: originalActiveIndex, tabTitle: parentWindow.title)
            }
        }

        debugLog("cacheBackgroundTabs: finished caching")
    }

    /// Try to find and click a tab with the given title in the window's tab bar
    /// targetIndex: which matching tab to click (0 = first, 1 = second, etc)
    private func selectTabByTitle(in window: AXUIElement, title: String, targetIndex: Int) -> Bool {
        debugLog("Looking for tab with title '\(title)' at index \(targetIndex)")

        // Try to find the tab bar/tab group
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else {
            debugLog("Could not get window children")
            return false
        }

        // Search recursively for tab-related elements
        var matchCount = 0
        let result = searchForTab(in: childElements, title: title, targetIndex: targetIndex, currentMatchCount: &matchCount, depth: 0)

        if !result {
            // Collect available tab titles for debugging
            var availableTabs: [String] = []
            collectTabTitles(in: childElements, into: &availableTabs, depth: 0)
            if !availableTabs.isEmpty {
                debugLog("Available tabs: \(availableTabs.joined(separator: ", "))")
                debugLog("Found \(matchCount) matching tabs, needed index \(targetIndex)")
            }
        }

        return result
    }

    /// Collect all tab titles from the AX hierarchy for debugging
    private func collectTabTitles(in elements: [AXUIElement], into titles: inout [String], depth: Int) {
        guard depth < 10 else { return }

        for element in elements {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let elementTitle = titleRef as? String ?? ""

            if (role == "AXRadioButton" || role == "AXTab") && !elementTitle.isEmpty {
                titles.append("'\(elementTitle)'")
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                collectTabTitles(in: children, into: &titles, depth: depth + 1)
            }
        }
    }

    private func searchForTab(in elements: [AXUIElement], title: String, targetIndex: Int, currentMatchCount: inout Int, depth: Int) -> Bool {
        guard depth < 10 else { return false }  // Prevent infinite recursion

        for element in elements {
            // Get role
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            // Get title/description
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)

            let elementTitle = titleRef as? String ?? ""
            let elementDesc = descRef as? String ?? ""

            if depth < 3 {
                debugLog("  \(String(repeating: "  ", count: depth))[\(role)] title='\(elementTitle)' desc='\(elementDesc)'")
            }

            // Check if this is a tab/radio button matching our title
            if (role == "AXRadioButton" || role == "AXButton" || role == "AXTab") &&
               !elementTitle.isEmpty && titlesMatch(wanted: title, tabTitle: elementTitle) {
                // Found a matching tab - check if it's the one we want
                if currentMatchCount == targetIndex {
                    debugLog("Found matching tab '\(elementTitle)' at index \(currentMatchCount)! Clicking...")
                    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    debugLog("Click result: \(result.rawValue)")
                    return result == .success
                } else {
                    debugLog("Found matching tab '\(elementTitle)' at index \(currentMatchCount), need index \(targetIndex), skipping")
                    currentMatchCount += 1
                }
            }

            // Recurse into children
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                if searchForTab(in: children, title: title, targetIndex: targetIndex, currentMatchCount: &currentMatchCount, depth: depth + 1) {
                    return true
                }
            }
        }

        return false
    }

    /// Match window title (potentially truncated with …) to AX tab title (full)
    /// CGWindowList may report: "…/GitHub/ghostty/ghostty"
    /// AX tabs report full: "~/git/ghostty/ghostty"
    private func titlesMatch(wanted: String, tabTitle: String) -> Bool {
        // Exact match
        if wanted == tabTitle {
            return true
        }

        // Handle ellipsis-truncated titles from CGWindowList
        // "…/something" should match "~/path/to/something" (path ending)
        if wanted.hasPrefix("…") {
            let suffix = String(wanted.dropFirst()) // Remove …
            // The tab title should end with this suffix
            return tabTitle.hasSuffix(suffix)
        }

        // Handle path matching - compare the final path component(s)
        // "~/git/ghostty/ghostty" should match tab "~/git/ghostty/ghostty"
        // but NOT match "~" or other shorter paths

        // If wanted is a path (contains /), require it to match exactly
        // or the tab title to end with the same path segments
        if wanted.contains("/") && tabTitle.contains("/") {
            // Get last 2-3 path components and compare
            let wantedComponents = wanted.split(separator: "/").suffix(3)
            let tabComponents = tabTitle.split(separator: "/").suffix(3)

            // If we have the same final components, it's a match
            if wantedComponents == tabComponents {
                return true
            }
        }

        return false
    }

    private func bringAppToFront(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        // Make sure the app is not hidden
        if app.isHidden {
            app.unhide()
        }

        // First, raise the frontmost window via AX (like Switch does)
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement],
           let frontWindow = axWindows.first {
            AXUIElementPerformAction(frontWindow, kAXRaiseAction as CFString)
        }

        // Then activate the app (this updates the menu bar)
        app.activate()

        // For setting AX attributes
        let trueValue: CFTypeRef = kCFBooleanTrue

        // Find the main content area (text area, scroll area, etc.) in a window
        func findContentArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 8 else { return nil }

            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            // These roles typically represent the main content area
            if role == "AXTextArea" || role == "AXWebArea" || (role == "AXGroup" && depth > 2) {
                return element
            }

            // Recurse into children
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                // Prefer larger children (main content is usually bigger)
                for child in children {
                    if let found = findContentArea(in: child, depth: depth + 1) {
                        return found
                    }
                }
            }
            return nil
        }

        // Helper to ensure window has keyboard focus
        func ensureFocus() {
            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let axWindow = focusedWindow as! AXUIElement? {
                // Raise the window
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

                // Set it as main and focused
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, trueValue)
                AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, trueValue)

                // Try to find and focus the content area directly
                if let contentArea = findContentArea(in: axWindow) {
                    var roleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(contentArea, kAXRoleAttribute as CFString, &roleRef)
                    debugLog("Found content area with role: \(roleRef as? String ?? "unknown")")
                    AXUIElementSetAttributeValue(contentArea, kAXFocusedAttribute as CFString, trueValue)
                } else {
                    debugLog("No content area found, using focused element fallback")
                    // Fallback: try to focus whatever is currently focused
                    var focusedElement: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
                       let element = focusedElement as! AXUIElement? {
                        var roleRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                        debugLog("Focusing element with role: \(roleRef as? String ?? "unknown")")
                        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, trueValue)
                    }
                }
            }

            // Re-activate to ensure keyboard focus
            app.activate()
        }

        // Multiple retry attempts with increasing delays
        // Some apps need more time for their window state to settle after tab switches
        let delays: [Double] = [0.05, 0.1, 0.2]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                ensureFocus()
            }
        }
    }


    /// Raise window visually for cycling preview (no focus steal)
    func raiseWindowForPreview(_ windowID: UInt32) {
        guard let window = windows.first(where: { $0.windowID == windowID }) else { return }

        // For background tabs, we need to switch to the tab first
        if window.parentWindowID != nil {
            let appElement = AXUIElementCreateApplication(window.pid)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let axWindows = windowsRef as? [AXUIElement] {
                for axWindow in axWindows {
                    if selectTabByTitle(in: axWindow, title: window.title, targetIndex: window.tabIndex) {
                        break
                    }
                }
            }
        }

        // Use private API to bring window to front without making it key
        // This raises the window visually but doesn't steal keyboard focus
        var psn = ProcessSerialNumber()
        GetProcessForPID(window.pid, &psn)

        let targetWindowID = window.parentWindowID ?? windowID
        // Use allWindows mode - brings process to front with all its windows
        _SLPSSetFrontProcessWithOptions(&psn, targetWindowID, SLPSMode.allWindows.rawValue)
    }


    /// Focus a window, switching spaces if necessary.
    ///
    /// Uses alt-tab's proven focus sequence with private SkyLight APIs:
    /// 1. `_SLPSSetFrontProcessWithOptions` with `userGenerated` mode (0x200)
    ///    - Brings the process to front and signals user intent for space switch
    /// 2. `makeKeyWindow` via `SLPSPostEventRecordTo`
    ///    - Sends binary protocol to WindowServer to make the window key
    /// 3. `AXUIElementPerformAction(element, kAXRaiseAction)`
    ///    - This is the crucial step that actually triggers space switching
    ///
    /// For windows on other spaces, the normal AX API can't find them, so we use
    /// `findAXUIElement(forWindowID:pid:)` to brute-force discover the element.
    func focusWindow(_ windowID: UInt32) {
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            debugLog("focusWindow: window \(windowID) not found")
            return
        }

        debugLog("focusWindow: \(window.appName) '\(window.title)' isOnCurrentSpace=\(window.isOnCurrentSpace) parentWindowID=\(window.parentWindowID?.description ?? "nil") tabIndex=\(window.tabIndex)")

        let targetWindowID = window.parentWindowID ?? windowID

        // Handle background tabs first - switch to the correct tab
        let isBackgroundTab = window.parentWindowID != nil
        if isBackgroundTab {
            debugLog("focusWindow: this is a background tab (index \(window.tabIndex)), trying to switch")
            // Try AppleScript first (more reliable for Terminal, Safari, etc.)
            let tabSwitchResult = selectTabViaAppleScript(
                appName: window.appName,
                pid: window.pid,
                tabTitle: window.title,
                tabIndex: window.tabIndex
            )
            debugLog("focusWindow: tab switch via AppleScript returned \(tabSwitchResult)")
            if !tabSwitchResult {
                // Fall back to AX approach if AppleScript didn't work
                debugLog("focusWindow: AppleScript failed, trying AX fallback")
                let appElement = AXUIElementCreateApplication(window.pid)
                var windowsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                   let axWindows = windowsRef as? [AXUIElement] {
                    for axWindow in axWindows {
                        if selectTabByTitle(in: axWindow, title: window.title, targetIndex: window.tabIndex) {
                            break
                        }
                    }
                }
            }

            // For background tabs on current space, the tab click already focused the window.
            // Skip the full window activation sequence which can revert the tab selection.
            if window.isOnCurrentSpace {
                debugLog("focusWindow: background tab on current space, skipping window activation (tab click handled it)")
                return
            }
        }

        // Use alt-tab's proven focus sequence:
        // 1. SLPSSetFrontProcessWithOptions with userGenerated mode
        //    - This brings the process to front AND triggers space switch if needed
        // 2. makeKeyWindow via SLPSPostEventRecordTo
        //    - Ensures the specific window becomes key
        // 3. AXRaise to ensure proper z-order

        var psn = ProcessSerialNumber()
        GetProcessForPID(window.pid, &psn)

        debugLog("focusWindow: calling _SLPSSetFrontProcessWithOptions with userGenerated mode")
        _SLPSSetFrontProcessWithOptions(&psn, targetWindowID, SLPSMode.userGenerated.rawValue)

        debugLog("focusWindow: calling makeKeyWindow")
        makeKeyWindow(&psn, targetWindowID)

        // Raise via AX API - need to find the AXUIElement for this window
        // For windows on other spaces, the normal AX API won't return them,
        // so we use alt-tab's brute-force approach with _AXUIElementCreateWithRemoteToken
        var targetAxElement: AXUIElement? = nil

        // First try the normal approach (faster, works for current-space windows)
        let appElement = AXUIElementCreateApplication(window.pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            for axWindow in axWindows {
                var windowIDRef: UInt32 = 0
                if _AXUIElementGetWindow(axWindow, &windowIDRef) == .success,
                   windowIDRef == targetWindowID {
                    targetAxElement = axWindow
                    debugLog("focusWindow: found AXUIElement via normal API")
                    break
                }
            }
        }

        // If not found, use brute-force approach for other-space windows
        if targetAxElement == nil && !window.isOnCurrentSpace {
            debugLog("focusWindow: window not on current space, using brute-force AXUIElement discovery")
            targetAxElement = findAXUIElement(forWindowID: targetWindowID, pid: window.pid)
            if targetAxElement != nil {
                debugLog("focusWindow: found AXUIElement via brute-force")
            } else {
                debugLog("focusWindow: brute-force failed to find AXUIElement")
            }
        }

        // Perform AXRaise
        if let axElement = targetAxElement {
            debugLog("focusWindow: performing AXRaise")
            AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        } else {
            debugLog("focusWindow: no AXUIElement found, skipping AXRaise")
        }
    }
}
