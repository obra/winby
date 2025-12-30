import Cocoa
import SwiftUI
import ScreenCaptureKit
import Vision
import KeyboardShortcuts
import Sparkle

// MARK: - Keyboard Shortcuts

extension KeyboardShortcuts.Name {
    static let toggleWinby = Self("toggleWinby", default: .init(.space, modifiers: [.command, .shift]))
}

// MARK: - Configuration

class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @Published var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }

    init() {
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
    }

    @MainActor
    var hotkeyDescription: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleWinby) {
            return shortcut.description
        }
        return "Not set"
    }
}

// Debug logging to file (only when debug mode enabled)
func debugLog(_ message: String) {
    guard AppConfig.shared.debugMode else { return }
    let logFile = "/tmp/wm_debug.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

// MARK: - Private API Declarations

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

@_silgen_name("SLSGetWindowBounds")
func SLSGetWindowBounds(_ cid: Int32, _ wid: UInt32, _ frame: UnsafeMutablePointer<CGRect>) -> CGError

@_silgen_name("SLSMoveWindow")
func SLSMoveWindow(_ cid: Int32, _ wid: UInt32, _ point: UnsafeMutablePointer<CGPoint>) -> CGError

@_silgen_name("SLSSetWindowAlpha")
func SLSSetWindowAlpha(_ cid: Int32, _ wid: UInt32, _ alpha: Float) -> CGError

@_silgen_name("SLSGetWindowOwner")
func SLSGetWindowOwner(_ cid: Int32, _ wid: UInt32, _ owner_cid: UnsafeMutablePointer<Int32>) -> CGError

@_silgen_name("SLSConnectionGetPID")
func SLSConnectionGetPID(_ cid: Int32, _ pid: UnsafeMutablePointer<pid_t>) -> CGError

// Private API to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

// MARK: - Async Semaphore

actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.count = limit
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}

// MARK: - Window Info

struct WindowInfo: Identifiable, Hashable {
    let id: UInt32  // CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    var duplicateIndex: Int = 0  // 0-based index for windows with same title in same app

    var displayTitle: String {
        if title.isEmpty {
            return appName
        }
        if duplicateIndex > 0 {
            return "\(title) (\(duplicateIndex + 1))"
        }
        return title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Window Manager

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var windows: [WindowInfo] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var maximizedWindowID: UInt32? = nil
    @Published var sidebarResetTrigger: Bool = false  // Toggle to reset sidebar state

    private let cid: Int32
    private var refreshTimer: Timer?

    /// Cached thumbnails - kept even when windows go to background
    var thumbnailCache: [UInt32: NSImage] = [:]

    /// Saved window positions for undo
    var savedPositions: [UInt32: CGRect] = [:]

    /// Cached window content for search (windowID -> content snippet)
    var contentCache: [UInt32: String] = [:]

    /// Windows we've already tried and failed to get content from (don't retry)
    var contentFailed: Set<UInt32> = []

    /// Screenshot hashes for change detection (windowID -> hash)
    var screenshotHashes: [UInt32: Int] = [:]

    /// Content search results (windowID -> match score)
    @Published var contentMatches: [UInt32: Int] = [:]

    let sidebarWidth: CGFloat = 250

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
    private func getTabTitles(from window: AXUIElement) -> [String] {
        var tabs: [String] = []

        // Look for AXTabGroup in children
        func findTabs(in element: AXUIElement, depth: Int = 0) {
            guard depth < 5 else { return }

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {

                // Found a tab group - get its tabs
                if role == "AXTabGroup" {
                    var tabsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXTabsAttribute as CFString, &tabsRef) == .success,
                       let tabElements = tabsRef as? [AXUIElement] {
                        for tab in tabElements {
                            var titleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef) == .success,
                               let title = titleRef as? String, !title.isEmpty {
                                tabs.append(title)
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
                        for child in children {
                            var childRoleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRoleRef) == .success,
                               let childRole = childRoleRef as? String,
                               childRole == "AXRadioButton" {
                                var titleRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                                   let title = titleRef as? String, !title.isEmpty {
                                    tabs.append(title)
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
        return tabs
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
    func quickImageHash(_ cgImage: CGImage) -> Int {
        var hasher = Hasher()
        // Sample a grid of pixels across the image
        let width = cgImage.width
        let height = cgImage.height
        let stepX = max(width / 16, 1)
        let stepY = max(height / 16, 1)

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return 0
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                // Sample RGB values
                if bytesPerPixel >= 3 {
                    hasher.combine(bytes[offset])      // R
                    hasher.combine(bytes[offset + 1])  // G
                    hasher.combine(bytes[offset + 2])  // B
                }
            }
        }

        return hasher.finalize()
    }

    /// Extract text from an image using Vision OCR
    func ocrImage(_ image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            debugLog("OCR: Failed to get CGImage from NSImage")
            return nil
        }

        debugLog("OCR: Processing image \(cgImage.width)x\(cgImage.height)")

        var recognizedText = ""
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                debugLog("OCR error: \(error)")
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            // Sort observations by Y position (top to bottom), then X (left to right)
            let sorted = observations.sorted { obs1, obs2 in
                // Vision uses normalized coords where Y=1 is top, Y=0 is bottom
                if abs(obs1.boundingBox.midY - obs2.boundingBox.midY) > 0.02 {
                    return obs1.boundingBox.midY > obs2.boundingBox.midY  // Higher Y = higher on screen
                }
                return obs1.boundingBox.midX < obs2.boundingBox.midX
            }

            for observation in sorted {
                if let candidate = observation.topCandidates(1).first {
                    if !recognizedText.isEmpty { recognizedText += " " }
                    recognizedText += candidate.string
                }
            }
        }
        request.recognitionLevel = .accurate  // Better quality
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3  // Latest revision

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            debugLog("OCR handler error: \(error)")
            return nil
        }

        debugLog("OCR: Got \(recognizedText.count) chars")
        return recognizedText.isEmpty ? nil : recognizedText
    }

    /// Get content via OCR from a full-size window capture
    /// Returns nil if capture failed, returns cached content if screenshot unchanged
    func getWindowContentViaOCR(windowID: UInt32) async -> String? {
        // Capture at higher resolution for OCR (thumbnails are too small)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            // Use actual window size or cap at reasonable resolution for OCR
            config.width = min(Int(scWindow.frame.width), 1920)
            config.height = min(Int(scWindow.frame.height), 1080)
            config.scalesToFit = false
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // Check if screenshot changed - if not, use cached content
            let newHash = quickImageHash(cgImage)
            if let oldHash = screenshotHashes[windowID], oldHash == newHash {
                // Screenshot unchanged, return cached content
                if let cached = contentCache[windowID] {
                    debugLog("OCR: Screenshot unchanged for window \(windowID), using cache")
                    return cached
                }
            }

            // Screenshot changed or no cache, run OCR
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if let text = ocrImage(nsImage) {
                // Update hash for next comparison
                await MainActor.run {
                    screenshotHashes[windowID] = newHash
                }
                return text
            }
            return nil
        } catch {
            debugLog("OCR capture error for window \(windowID): \(error)")
            return nil
        }
    }

    /// Debug: dump what content we can get from all windows
    func debugContentFetch() {
        debugLog("=== Content fetch debug ===")
        for window in windows {
            if let content = getWindowContent(windowID: window.id, pid: window.pid) {
                let preview = String(content.prefix(200)).replacingOccurrences(of: "\n", with: "\\n")
                debugLog("[\(window.appName)] '\(window.title)': \(content.count) chars - '\(preview)...'")
            } else {
                debugLog("[\(window.appName)] '\(window.title)': NO CONTENT")
            }
        }
        debugLog("=== End content debug ===")
    }

    /// Background queue for content indexing
    private static let indexQueue = DispatchQueue(label: "content-index", qos: .utility, attributes: .concurrent)
    private var isIndexing = false

    /// Track when windows were last indexed (for refresh)
    private var lastIndexed: [UInt32: Date] = [:]

    /// Index content for all windows in background (10 at a time, using OCR)
    func indexContentInBackground() {
        guard !isIndexing else { return }
        isIndexing = true

        let now = Date()
        let refreshInterval: TimeInterval = 10  // Re-index on-screen windows every 10 seconds

        // Index windows that:
        // 1. Have no content and haven't failed, OR
        // 2. Are on-screen and haven't been indexed recently (content may have changed)
        let windowsCopy = windows.filter { window in
            if contentCache[window.id] == nil && !contentFailed.contains(window.id) {
                return true  // Never indexed
            }
            if window.isOnScreen, let lastTime = lastIndexed[window.id],
               now.timeIntervalSince(lastTime) > refreshInterval {
                return true  // On-screen and stale
            }
            return false
        }

        guard !windowsCopy.isEmpty else {
            isIndexing = false
            return
        }

        Task {
            await withTaskGroup(of: Void.self) { group in
                let semaphore = AsyncSemaphore(limit: 10)

                for window in windowsCopy {
                    group.addTask { [weak self] in
                        await semaphore.wait()

                        guard let self = self else {
                            await semaphore.signal()
                            return
                        }

                        // Only try OCR on on-screen windows (can't capture off-screen)
                        if window.isOnScreen {
                            if let content = await self.getWindowContentViaOCR(windowID: window.id), content.count > 20 {
                                await MainActor.run {
                                    self.contentCache[window.id] = content
                                    self.lastIndexed[window.id] = Date()
                                }
                                await semaphore.signal()
                                return
                            }
                        }

                        // Fall back to AX API (works for all windows)
                        if let content = self.getWindowContent(windowID: window.id, pid: window.pid), content.count > 20 {
                            await MainActor.run {
                                self.contentCache[window.id] = content
                                self.lastIndexed[window.id] = Date()
                            }
                        } else if !window.isOnScreen {
                            // Only mark as failed if off-screen (on-screen might succeed later)
                            _ = await MainActor.run {
                                self.contentFailed.insert(window.id)
                            }
                        }

                        await semaphore.signal()
                    }
                }
            }

            await MainActor.run { [weak self] in
                self?.isIndexing = false
            }
        }
    }

    /// Search cached content only (instant, never blocks)
    func searchContent(query: String) async {
        guard !query.isEmpty else {
            contentMatches = [:]
            return
        }

        let queryLower = query.lowercased()
        let terms = queryLower.split(separator: " ").map { String($0) }

        var newMatches: [UInt32: Int] = [:]

        // Search only cached content - instant
        for window in windows {
            guard let content = contentCache[window.id] else { continue }

            let contentLower = content.lowercased()
            var totalScore = 0
            var allMatch = true

            for term in terms {
                if contentLower.contains(term) {
                    totalScore += term.count * 2
                } else {
                    allMatch = false
                    break
                }
            }

            if allMatch && totalScore > 0 {
                newMatches[window.id] = totalScore
            }
        }

        contentMatches = newMatches
    }

    /// Clear content cache for a window (call when window content might have changed)
    func invalidateContentCache(for windowID: UInt32) {
        contentCache.removeValue(forKey: windowID)
        contentFailed.remove(windowID)
    }

    /// Clear all content caches
    func clearContentCache() {
        contentCache.removeAll()
        contentMatches.removeAll()
        contentFailed.removeAll()
    }

    func refresh() {
        // Build a map of CGWindowID -> window info from CGWindowList
        // This gives us frame info and isOnScreen status
        var cgWindowInfo: [UInt32: (frame: CGRect, isOnScreen: Bool, title: String)] = [:]

        if let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for windowDict in windowList {
                guard let windowID = windowDict[kCGWindowNumber as String] as? UInt32,
                      let boundsDict = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                      let layer = windowDict[kCGWindowLayer as String] as? Int,
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
                cgWindowInfo[windowID] = (frame, isOnScreen, title)
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

                // Add the main window
                newWindows.append(WindowInfo(
                    id: windowID,
                    pid: pid,
                    appName: appName,
                    title: title,
                    frame: frame,
                    isOnScreen: isOnScreen
                ))

                // Check for tabs in this window and add them
                let tabTitles = getTabTitles(from: axWindow)
                for tabTitle in tabTitles {
                    // Skip if this tab is already the window title (it's the active tab)
                    if tabTitle == title { continue }

                    // Look up CGWindowID for this tab from our map
                    // Background tabs should be in cgWindowInfo from CGWindowList
                    var tabWindowID: UInt32? = nil
                    for (cgID, cgInfo) in cgWindowInfo {
                        if cgInfo.title == tabTitle || cgInfo.title.hasSuffix(tabTitle) {
                            tabWindowID = cgID
                            break
                        }
                    }

                    // Add tab entry (use parent window ID if we can't find specific one)
                    newWindows.append(WindowInfo(
                        id: tabWindowID ?? windowID,
                        pid: pid,
                        appName: appName,
                        title: tabTitle,
                        frame: frame,  // Use parent frame since background tabs aren't positioned
                        isOnScreen: false
                    ))
                }
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

        DispatchQueue.main.async {
            self.windows = newWindows
            // Index content in background for instant search
            self.indexContentInBackground()
        }
    }

    func thumbnail(for windowID: UInt32, maxSize: CGSize = CGSize(width: 200, height: 150)) async -> NSImage? {
        // Return cached if available
        if let cached = thumbnailCache[windowID] {
            return cached
        }

        // Try ScreenCaptureKit
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                config.width = Int(maxSize.width * 2)
                config.height = Int(maxSize.height * 2)
                config.scalesToFit = true
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImage = NSImage(cgImage: image, size: maxSize)
                thumbnailCache[windowID] = nsImage
                return nsImage
            }
        } catch {
            // ScreenCaptureKit failed - silently fall back to app icon
            // (permission denied is expected if user hasn't granted screen recording)
        }

        // Fallback: use app icon
        if let window = windows.first(where: { $0.id == windowID }),
           let app = NSRunningApplication(processIdentifier: window.pid),
           let icon = app.icon {
            return icon
        }

        return nil
    }

    func bringToFront(_ windowID: UInt32) {
        guard let window = windows.first(where: { $0.id == windowID }) else {
            debugLog("Window \(windowID) not found in list")
            return
        }

        debugLog("Trying to raise window \(windowID) '\(window.title)' from \(window.appName)")

        // Restore any previously maximized window, then maximize this one
        if let prevID = maximizedWindowID, prevID != windowID {
            restoreWindow(prevID)
        }
        if maximizedWindowID != windowID {
            maximizeWindow(windowID)
        }

        // Use Accessibility API to raise the specific window
        let appElement = AXUIElementCreateApplication(window.pid)

        // Get all windows for this app
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            debugLog("Could not get AX windows, falling back to app activation")
            bringAppToFront(pid: window.pid)
            return
        }

        debugLog("Found \(axWindows.count) AX windows for pid \(window.pid)")

        // Find the window matching our windowID using private API
        for axWindow in axWindows {
            var axWindowID: UInt32 = 0
            let getWindowResult = _AXUIElementGetWindow(axWindow, &axWindowID)
            debugLog("AX window has ID \(axWindowID), looking for \(windowID), result: \(getWindowResult.rawValue)")

            if getWindowResult == .success && axWindowID == windowID {
                // Found it! Try multiple approaches to raise it
                debugLog("MATCH! Found AX window for windowID \(windowID)")

                // Debug: print available actions
                var actionsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, "AXActionNames" as CFString, &actionsRef) == .success {
                    debugLog("Available actions: \(actionsRef ?? "none" as CFTypeRef)")
                }

                // 1. Try setting it as the main window
                let trueValue: CFTypeRef = kCFBooleanTrue
                let mainResult = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, trueValue)
                debugLog("Set main result: \(mainResult.rawValue)")

                // 2. Try AXRaise action
                let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                debugLog("Raise result: \(raiseResult.rawValue)")

                // 3. Try AXPress action (works for some tab implementations)
                let pressResult = AXUIElementPerformAction(axWindow, kAXPressAction as CFString)
                debugLog("Press result: \(pressResult.rawValue)")

                // 4. Bring app to front
                bringAppToFront(pid: window.pid)
                return
            }
        }

        debugLog("No AX window matched windowID \(windowID), trying tab bar approach (index \(window.duplicateIndex))")

        // For native tabs: search ALL windows in the app for the tab
        // The tab might be in a different window than the currently visible one
        for (idx, axWindow) in axWindows.enumerated() {
            debugLog("Searching window \(idx + 1) of \(axWindows.count) for tab")
            if selectTabByTitle(in: axWindow, title: window.title, targetIndex: window.duplicateIndex) {
                bringAppToFront(pid: window.pid)
                return
            }
        }

        // Last fallback: just bring app to front
        debugLog("All methods failed, just bringing app to front")
        bringAppToFront(pid: window.pid)
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
        let app = NSRunningApplication(processIdentifier: pid)
        app?.activate()
    }

    /// Maximize a window to fill the screen (minus sidebar)
    func maximizeWindow(_ windowID: UInt32) {
        guard let window = windows.first(where: { $0.id == windowID }),
              let screen = NSScreen.main else { return }

        // Save current position/size before maximizing (only if it has a real frame)
        if savedPositions[windowID] == nil && window.frame.width > 0 && window.frame.height > 0 {
            savedPositions[windowID] = window.frame
            debugLog("Saved original frame: \(window.frame)")
        }

        let screenFrame = screen.visibleFrame

        // Calculate target frame in Cocoa coordinates (origin at bottom-left)
        // Window should be right of sidebar and fill the rest of visible area
        let x = screenFrame.origin.x + sidebarWidth
        let y = screenFrame.origin.y  // Bottom of visible frame
        let width = screenFrame.width - sidebarWidth
        let height = screenFrame.height

        let targetFrame = CGRect(x: x, y: y, width: width, height: height)
        debugLog("Maximizing window \(windowID) to frame: \(targetFrame) (screenFrame: \(screenFrame))")

        // Use AX API for both position and size (more reliable than SkyLight for most apps)
        resizeAndMoveWindow(windowID, pid: window.pid, to: targetFrame)

        maximizedWindowID = windowID
    }

    /// Restore a maximized window to its original size/position
    func restoreWindow(_ windowID: UInt32? = nil) {
        let targetID = windowID ?? maximizedWindowID
        guard let id = targetID,
              let originalFrame = savedPositions[id],
              let window = windows.first(where: { $0.id == id }) else { return }

        guard let screen = NSScreen.main else { return }

        // savedPositions stores CG coordinates (origin at top-left)
        // AX API uses Cocoa coordinates (origin at bottom-left)
        // Convert: cocoaY = screenHeight - cgY - windowHeight
        let screenHeight = screen.frame.height
        let cocoaY = screenHeight - originalFrame.origin.y - originalFrame.height
        let cocoaFrame = CGRect(
            x: originalFrame.origin.x,
            y: cocoaY,
            width: originalFrame.width,
            height: originalFrame.height
        )

        debugLog("Restoring window \(id) from CG \(originalFrame) to Cocoa \(cocoaFrame)")
        resizeAndMoveWindow(id, pid: window.pid, to: cocoaFrame)

        savedPositions.removeValue(forKey: id)
        if maximizedWindowID == id {
            maximizedWindowID = nil
        }
    }

    /// Toggle maximize/restore for a window
    func toggleMaximize(_ windowID: UInt32) {
        if maximizedWindowID == windowID {
            restoreWindow(windowID)
        } else {
            // Restore previous maximized window first
            if let prev = maximizedWindowID {
                restoreWindow(prev)
            }
            maximizeWindow(windowID)
        }
    }

    private func resizeAndMoveWindow(_ windowID: UInt32, pid: pid_t, to frame: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            debugLog("resizeAndMoveWindow: couldn't get AX windows for pid \(pid)")
            return
        }

        for axWindow in axWindows {
            var axWindowID: UInt32 = 0
            if _AXUIElementGetWindow(axWindow, &axWindowID) == .success && axWindowID == windowID {
                debugLog("Found AX window \(axWindowID), setting frame to \(frame)")

                // AX uses Cocoa coordinates (origin at bottom-left of main screen)
                // frame parameter is in Cocoa coordinates
                var position = frame.origin
                if let posRef = AXValueCreate(.cgPoint, &position) {
                    let posResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posRef)
                    debugLog("Position set result: \(posResult.rawValue)")
                }

                var size = frame.size
                if let sizeRef = AXValueCreate(.cgSize, &size) {
                    let sizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeRef)
                    debugLog("Size set result: \(sizeResult.rawValue)")
                }
                return
            }
        }
        debugLog("resizeAndMoveWindow: window \(windowID) not found in AX windows")
    }

    func moveWindow(_ windowID: UInt32, to point: CGPoint) {
        var p = point
        _ = SLSMoveWindow(cid, windowID, &p)
    }
}

// MARK: - SwiftUI Views

struct WindowRow: View {
    let window: WindowInfo
    let isSelected: Bool
    let isMaximized: Bool
    let hasContentMatch: Bool
    let thumbnail: NSImage?
    let onSelect: () -> Void
    let onMaximize: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Thumbnail
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 45)
                        .cornerRadius(4)
                        .shadow(radius: 1)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 60, height: 45)
                        .cornerRadius(4)
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if hasContentMatch {
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 9))
                                .foregroundColor(.blue)
                                .help("Matched in window content")
                        }
                    }
                    Text(window.appName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Maximized indicator
                if isMaximized {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.3) :
            isMaximized ? Color.accentColor.opacity(0.1) : Color.clear
        )
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contextMenu {
            Button(isMaximized ? "Restore Size" : "Maximize") {
                onMaximize()
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var config = AppConfig.shared

    var body: some View {
        Form {
            Section("Activation Shortcut") {
                KeyboardShortcuts.Recorder("Show Winby:", name: .toggleWinby)
            }

            Section("General") {
                Toggle("Debug Mode", isOn: $config.debugMode)
                    .help("Show debug controls and log to /tmp/wm_debug.log")
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 200)
        .padding()
    }
}

struct SidebarView: View {
    @ObservedObject var manager = WindowManager.shared
    @ObservedObject var config = AppConfig.shared
    @State private var thumbnails: [UInt32: NSImage] = [:]
    @State private var searchText = ""
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var isSearchingContent = false
    @State private var showDebugPanel = false
    @State private var debugContent = ""
    @FocusState private var isSearchFocused: Bool

    var filteredWindows: [WindowInfo] {
        if searchText.isEmpty {
            return manager.windows
        }
        // Fuzzy match and sort by score (including content matches)
        let query = searchText.lowercased()
        let scored = manager.windows.compactMap { window -> (WindowInfo, Int)? in
            let titleScore = fuzzyMatch(query: query, in: window.displayTitle.lowercased())
            let appScore = fuzzyMatch(query: query, in: window.appName.lowercased())
            let contentScore = manager.contentMatches[window.id] ?? 0

            // Window matches if title/app matches OR content matches
            let titleAppScore = max(titleScore, appScore)
            if titleAppScore > 0 || contentScore > 0 {
                return (window, titleAppScore + contentScore)
            }
            return nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Trigger debounced content search
    func triggerContentSearch() {
        contentSearchTask?.cancel()
        contentSearchTask = Task {
            // Debounce: wait 300ms before searching
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { isSearchingContent = true }
            await manager.searchContent(query: searchText)
            await MainActor.run { isSearchingContent = false }
        }
    }

    /// Fuzzy match a single term against text - returns score (0 = no match, higher = better)
    func fuzzyMatchTerm(_ term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }

        var score = 0
        var termIndex = term.startIndex
        var textIndex = text.startIndex
        var consecutiveBonus = 0

        while termIndex < term.endIndex && textIndex < text.endIndex {
            if term[termIndex] == text[textIndex] {
                score += 1 + consecutiveBonus
                consecutiveBonus += 1  // Bonus for consecutive matches
                termIndex = term.index(after: termIndex)
            } else {
                consecutiveBonus = 0
            }
            textIndex = text.index(after: textIndex)
        }

        // Only return score if we matched all term characters
        return termIndex == term.endIndex ? score : 0
    }

    /// Fuzzy match query against text. Space-separated terms are matched independently.
    /// All terms must match for a non-zero score.
    func fuzzyMatch(query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }

        let terms = query.split(separator: " ").map { String($0) }
        guard !terms.isEmpty else { return 0 }

        var totalScore = 0
        for term in terms {
            let termScore = fuzzyMatchTerm(term, in: text)
            if termScore == 0 {
                return 0  // All terms must match
            }
            totalScore += termScore
        }

        return totalScore
    }

    /// Flat list of windows for keyboard navigation (matches visual order)
    var flatWindowList: [WindowInfo] {
        groupedWindows.flatMap { $0.1 }
    }

    var groupedWindows: [(String, [WindowInfo])] {
        let grouped = Dictionary(grouping: filteredWindows, by: { $0.appName })
        return grouped.sorted { $0.key < $1.key }
    }

    func selectNext() {
        let list = flatWindowList
        guard !list.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = list.firstIndex(where: { $0.id == current }) {
            let nextIdx = min(idx + 1, list.count - 1)
            manager.selectedWindowID = list[nextIdx].id
        } else {
            manager.selectedWindowID = list[0].id
        }
    }

    func selectPrevious() {
        let list = flatWindowList
        guard !list.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = list.firstIndex(where: { $0.id == current }) {
            let prevIdx = max(idx - 1, 0)
            manager.selectedWindowID = list[prevIdx].id
        } else {
            manager.selectedWindowID = list[0].id
        }
    }

    func activateSelected() {
        if let windowID = manager.selectedWindowID {
            manager.bringToFront(windowID)
            searchText = ""
            // Hide sidebar after selecting a window
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.hideSidebar()
            }
        }
    }

    /// Update debug content when selection changes
    func updateDebugContent() {
        guard showDebugPanel, let windowID = manager.selectedWindowID,
              let window = manager.windows.first(where: { $0.id == windowID }) else {
            debugContent = "No window selected"
            return
        }

        debugContent = "Loading..."

        // Fetch content in background
        Task {
            var content = "=== \(window.appName): \(window.title) ===\n\n"

            // Get cached content
            if let cached = manager.contentCache[windowID] {
                content += "📋 CACHED CONTENT (\(cached.count) chars):\n"
                content += String(cached.prefix(3000)) + "\n\n"
            } else {
                content += "📋 CACHED: No cached content\n\n"
            }

            // Get fresh OCR (full-size capture)
            if let ocrText = await manager.getWindowContentViaOCR(windowID: windowID) {
                content += "🔍 FRESH OCR (\(ocrText.count) chars):\n"
                content += String(ocrText.prefix(3000)) + "\n\n"
            } else {
                content += "🔍 OCR: No text found (window may be off-screen)\n\n"
            }

            // Get fresh AX content
            if let axContent = manager.getWindowContent(windowID: windowID, pid: window.pid) {
                content += "♿ AX API (\(axContent.count) chars):\n"
                content += String(axContent.prefix(3000)) + "\n"
            } else {
                content += "♿ AX API: No content found\n"
            }

            await MainActor.run {
                debugContent = content
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main sidebar
            VStack(spacing: 0) {
                // Search
                HStack {
                    TextField("Search windows...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onChange(of: searchText) { _, newValue in
                            if newValue.isEmpty {
                                manager.contentMatches = [:]
                                contentSearchTask?.cancel()
                            } else {
                                triggerContentSearch()
                            }
                        }

                    if isSearchingContent {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }

                    // Debug toggle (only shown when debug mode enabled)
                    if config.debugMode {
                        Button(action: {
                            showDebugPanel.toggle()
                            if showDebugPanel { updateDebugContent() }
                        }) {
                            Image(systemName: showDebugPanel ? "ladybug.fill" : "ladybug")
                                .foregroundColor(showDebugPanel ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle debug panel")
                    }
                }
                .padding(8)

                Divider()

            // Window list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groupedWindows, id: \.0) { appName, windows in
                            Section {
                                ForEach(windows) { window in
                                    WindowRow(
                                        window: window,
                                        isSelected: manager.selectedWindowID == window.id,
                                        isMaximized: manager.maximizedWindowID == window.id,
                                        hasContentMatch: manager.contentMatches[window.id] != nil,
                                        thumbnail: thumbnails[window.id],
                                        onSelect: {
                                            manager.selectedWindowID = window.id
                                            manager.bringToFront(window.id)
                                            searchText = ""
                                            // Hide sidebar after selecting a window
                                            if let appDelegate = NSApp.delegate as? AppDelegate {
                                                appDelegate.hideSidebar()
                                            }
                                        },
                                        onMaximize: {
                                            manager.toggleMaximize(window.id)
                                        }
                                    )
                                    .id(window.id)
                                }
                            } header: {
                                Text(appName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 50)  // Extra space so last item can scroll into view
                }
                .onChange(of: manager.selectedWindowID) { _, newValue in
                    if let id = newValue {
                        // Use bottom anchor when near end of list for better visibility
                        let list = flatWindowList
                        let isNearEnd = list.last?.id == id
                        withAnimation {
                            proxy.scrollTo(id, anchor: isNearEnd ? .bottom : .center)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(manager.windows.count) windows")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if manager.maximizedWindowID != nil {
                    Button("Restore") {
                        manager.restoreWindow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                }
            }
                .padding(8)
            }
            .frame(width: 280)
            .background(Color.clear)

            // Debug panel (shown when debug mode is on)
            if showDebugPanel {
                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Debug: Content Extraction")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button("Refresh") {
                            updateDebugContent()
                        }
                        .font(.system(size: 10))
                    }
                    .padding(8)

                    Divider()

                    ScrollView {
                        Text(debugContent)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                .frame(width: 400)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .onKeyPress(.downArrow) {
            selectNext()
            if showDebugPanel { updateDebugContent() }
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectPrevious()
            if showDebugPanel { updateDebugContent() }
            return .handled
        }
        .onKeyPress(.return) {
            activateSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            if searchText.isEmpty {
                // If search is empty, dismiss sidebar
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.hideSidebar()
                }
            } else {
                // Otherwise just clear search
                searchText = ""
                manager.selectedWindowID = nil
            }
            return .handled
        }
        .onAppear {
            loadThumbnails()
        }
        .onChange(of: manager.windows) {
            loadThumbnails()
        }
        .onChange(of: manager.selectedWindowID) {
            if showDebugPanel { updateDebugContent() }
        }
        .onChange(of: manager.sidebarResetTrigger) {
            // Reset state when sidebar is hidden
            searchText = ""
            manager.selectedWindowID = nil
            manager.contentMatches = [:]
        }
    }

    func loadThumbnails() {
        Task {
            // Start with existing thumbnails to preserve cached ones
            var newThumbnails = thumbnails
            for window in manager.windows {
                if let thumb = await manager.thumbnail(for: window.id) {
                    newThumbnails[window.id] = thumb
                }
            }
            // Remove thumbnails for windows that no longer exist
            let currentIDs = Set(manager.windows.map { $0.id })
            newThumbnails = newThumbnails.filter { currentIDs.contains($0.key) }

            await MainActor.run {
                thumbnails = newThumbnails
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup global hotkey (Cmd+Shift+Space to focus switcher)
        setupGlobalHotkey()
        // Request screen capture permission using CoreGraphics API
        // This should trigger the permission dialog
        if !CGPreflightScreenCaptureAccess() {
            debugLog("Requesting screen capture permission...")
            let granted = CGRequestScreenCaptureAccess()
            debugLog("Screen capture permission granted: \(granted)")
        } else {
            debugLog("Screen capture permission already granted")
        }

        // Also try ScreenCaptureKit
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                debugLog("ScreenCaptureKit access OK, found \(content.windows.count) windows")
            } catch {
                debugLog("ScreenCaptureKit error: \(error)")
            }
        }

        // Create floating panel window
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window = panel

        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        // Add visual effect background for translucency
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow

        let hostingView = NSHostingView(rootView: SidebarView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        panel.contentView = visualEffect

        // Position on left side of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: screenFrame.origin.x,
                    y: screenFrame.origin.y,
                    width: 280,
                    height: screenFrame.height
                ),
                display: true
            )
        }

        // Keep window on top
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.makeKeyAndOrderFront(nil)

        // Auto-hide when window loses focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        // Also add a status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Winby")
        statusItem?.menu = createMenu()

        // Set up main menu with Edit menu for standard shortcuts
        setupMainMenu()

        // Request accessibility permissions
        requestAccessibilityPermissions()
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)

        // Edit menu (for cmd+a/x/c/v)
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Winby (\(AppConfig.shared.hotkeyDescription))", action: #selector(toggleSidebar), keyEquivalent: "")
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Preferences...", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Winby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    var settingsWindow: NSWindow?

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.title = "Winby Preferences"
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func debugDumpContent() {
        WindowManager.shared.debugContentFetch()
        debugLog("Content dump written to /tmp/wm_debug.log")
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        // Auto-hide when sidebar loses focus
        hideSidebar()
    }

    @objc func toggleSidebar() {
        if window.isVisible {
            hideSidebar()
        } else {
            showSidebar()
        }
    }

    func showSidebar() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Start off-screen to the left
        window.setFrame(
            NSRect(
                x: screenFrame.origin.x - 250,
                y: screenFrame.origin.y,
                width: 280,
                height: screenFrame.height
            ),
            display: false
        )
        window.orderFront(nil)

        // Animate slide in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(
                NSRect(
                    x: screenFrame.origin.x,
                    y: screenFrame.origin.y,
                    width: 280,
                    height: screenFrame.height
                ),
                display: true
            )
        }

        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideSidebar() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Reset sidebar state
        WindowManager.shared.sidebarResetTrigger.toggle()

        // Animate slide out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(
                    x: screenFrame.origin.x - 250,
                    y: screenFrame.origin.y,
                    width: 280,
                    height: screenFrame.height
                ),
                display: true
            )
        }, completionHandler: {
            self.window.orderOut(nil)
        })
    }

    @objc func refreshWindows() {
        WindowManager.shared.refresh()
    }

    @objc func restoreMaximized() {
        WindowManager.shared.restoreWindow()
    }

    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("Accessibility permissions required for full functionality")
        }
    }

    func setupGlobalHotkey() {
        // Use KeyboardShortcuts library for global hotkey
        KeyboardShortcuts.onKeyDown(for: .toggleWinby) { [weak self] in
            self?.toggleSidebar()
        }
    }
}

// MARK: - Main

debugLog("WindowManager starting up")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Menubar app style
debugLog("App configured, running main loop")
app.run()
