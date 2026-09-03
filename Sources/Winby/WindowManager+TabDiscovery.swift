import Cocoa

// MARK: - Tab Discovery and Accessibility

extension WindowManager {
    /// Debug: dump AX hierarchy to find tab structure
    func dumpAXHierarchy(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 3) {
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
    func getTabTitles(from window: AXUIElement) -> (titles: [String], selectedIndex: Int) {
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

    /// Serial queue for AppleScript execution. NSAppleScript is not thread safe, so all
    /// sends share one queue; `qos: .utility` keeps them off the main thread entirely.
    private static let browserScriptQueue = DispatchQueue(
        label: "com.winby.browser-tab-discovery",
        qos: .utility
    )

    /// How long a cached browser tab list stays valid before we re-run the script.
    private static let browserTabCacheTTL: TimeInterval = 2.0

    /// Get browser tabs via AppleScript (Safari, Chrome, Arc have native scripting support)
    /// Returns (tabTitles, selectedIndex) or nil if not a supported browser.
    ///
    /// Non-blocking: returns the most recent cached result (nil until the first fetch
    /// completes, in which case callers fall back to AX-based tab detection) and kicks
    /// off a background refresh. Never runs AppleScript on the calling thread, because
    /// this is called from refresh() on the main thread.
    func getBrowserTabs(bundleId: String, appName: String) -> (titles: [String], selectedIndex: Int)? {
        guard let scriptSource = Self.browserTabScript(bundleId: bundleId, appName: appName) else {
            return nil
        }

        let key = bundleId.isEmpty ? appName : bundleId

        if claimBrowserTabFetch(key: key, ttl: Self.browserTabCacheTTL) {
            Self.browserScriptQueue.async { [weak self] in
                guard let self else { return }
                let result = Self.runBrowserTabScript(scriptSource)
                // Only overwrite a good result when the new one succeeded; a transient
                // script failure shouldn't make tabs disappear from the list.
                if let result {
                    self.setCachedBrowserTabs(key: key, value: result)
                }
                self.finishBrowserTabFetch(key: key)
            }
        }

        return getCachedBrowserTabs(key: key)
    }

    /// Builds the tab-listing script for supported browsers, or nil for other apps.
    /// Each script is wrapped in `with timeout` so a busy or wedged browser bounds the
    /// Apple Event wait instead of blocking for the two-minute AE default.
    private static func browserTabScript(bundleId: String, appName: String) -> String? {
        if bundleId == "com.apple.Safari" || appName == "Safari" {
            return """
            with timeout of 2 seconds
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
            end timeout
            """
        } else if bundleId == "com.google.Chrome" || appName.contains("Chrome") {
            return """
            with timeout of 2 seconds
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
            end timeout
            """
        }
        return nil
    }

    /// Executes a tab-listing script and parses its {tabTitles, selectedIndex} result.
    /// Must only be called from `browserScriptQueue`.
    private static func runBrowserTabScript(_ source: String) -> (titles: [String], selectedIndex: Int)? {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return nil }

        let result = appleScript.executeAndReturnError(&error)
        if let error {
            debugLog("getBrowserTabs: AppleScript failed: \(error)")
            return nil
        }

        // Parse result - it's a list containing {tabTitles, selectedIndex}
        guard result.numberOfItems >= 2 else { return nil }

        let tabListDesc = result.atIndex(1)
        let selectedIdxDesc = result.atIndex(2)

        var titles: [String] = []
        if let tabList = tabListDesc, tabList.numberOfItems > 0 {
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
    func enableAppAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        // Enable for Electron apps
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
        // Enable for Chrome-based apps
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    }

    /// Try to get text from an element using multiple attribute approaches
    func getTextFromElement(_ element: AXUIElement) -> String? {
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
        // Skip AX introspection for sensitive apps (password managers)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        if isSensitiveApp(pid: pid, appName: appName) {
            return nil
        }

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
}
