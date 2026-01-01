import Cocoa
import SwiftUI
import ScreenCaptureKit
import Vision
import KeyboardShortcuts
import Sparkle
import ServiceManagement
import Carbon.HIToolbox

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

    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                debugLog("Failed to update launch at login: \(error)")
            }
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    init() {
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    // MARK: - Permission Helpers

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    var hotkeyDescription: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleWinby) {
            return shortcut.description
        }
        return "Not set"
    }

    /// Check if the configured shortcut is Cmd+Tab
    @MainActor
    var isCmdTabShortcut: Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleWinby) else { return false }
        return shortcut.key == .tab && shortcut.modifiers == .command
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

@_silgen_name("SLSOrderWindow")
func SLSOrderWindow(_ cid: Int32, _ wid: UInt32, _ mode: Int32, _ relativeToWid: UInt32) -> CGError

// Private APIs for focusing specific windows (from AltTab/Hammerspoon)
enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

/// Brings a specific window of a process to front
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

/// Sends bytes to the WindowServer (for making window key)
@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

/// Make a window the key window (from AltTab/Hammerspoon)
/// This sends special events to the WindowServer to ensure proper focus
func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x08] = 0x01
    bytes[0x3a] = 0x10

    // Fill bytes 0x20-0x2f with 0xff
    for i in 0x20...0x2f {
        bytes[i] = 0xff
    }

    // Copy windowID into bytes at offset 0x3c
    var wid = windowID
    withUnsafeBytes(of: &wid) { widBytes in
        for i in 0..<4 {
            bytes[0x3c + i] = widBytes[i]
        }
    }

    SLPSPostEventRecordTo(&psn, &bytes)

    // Second call with 0x02
    bytes[0x08] = 0x02
    SLPSPostEventRecordTo(&psn, &bytes)
}

/// Get process serial number from PID
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// Private API to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

// Private API to create AXUIElement from a remote token (for brute-forcing elements on other spaces)
// Token format: pid (4 bytes) + 0 (4 bytes) + 0x636f636f (4 bytes) + elementID (8 bytes) = 20 bytes
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

/// Brute-force find AXUIElement for a window ID on any space.
///
/// The normal AX API (`AXUIElementCopyAttributeValue` with `kAXWindowsAttribute`)
/// only returns windows on the current space. For windows on other spaces, we need
/// this brute-force approach using `_AXUIElementCreateWithRemoteToken`.
///
/// This technique was discovered by alt-tab-macos (issue #1324, Feb 2025):
/// 1. Construct a 20-byte token with the process PID and an element ID
/// 2. Iterate through element IDs 0-1000 (apps reuse IDs, so they stay low)
/// 3. For each valid element, check if its window ID matches our target
///
/// The token format is: pid (4 bytes) + 0 (4 bytes) + 0x636f636f (4 bytes) + elementID (8 bytes)
/// The magic number 0x636f636f is "coco" in ASCII, likely a Cocoa marker.
///
/// Why this matters: Without the AXUIElement, calling `_SLPSSetFrontProcessWithOptions`
/// will activate the window within its space, but won't trigger the space switch animation.
/// You MUST call `AXUIElementPerformAction(element, kAXRaiseAction)` with a valid element
/// to make macOS switch to that space.
///
/// - Parameters:
///   - targetWindowID: The CGWindowID of the window to find
///   - pid: The process ID that owns the window
/// - Returns: The AXUIElement if found, nil otherwise
func findAXUIElement(forWindowID targetWindowID: UInt32, pid: pid_t) -> AXUIElement? {
    // Token format: pid (4 bytes) + 0 (4 bytes) + 0x636f636f (4 bytes) + elementID (8 bytes)
    var remoteToken = Data(count: 20)
    remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

    // Iterate through element IDs (alt-tab uses 0-1000 with 100ms timeout)
    for elementID: UInt64 in 0..<1000 {
        remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })

        guard let element = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue() else {
            continue
        }

        // Check if this element corresponds to our target window
        var windowID: UInt32 = 0
        if _AXUIElementGetWindow(element, &windowID) == .success && windowID == targetWindowID {
            return element
        }
    }

    return nil
}

// Private API to enable/disable system hotkeys
@_silgen_name("CGSSetGlobalHotKeyOperatingMode")
func CGSSetGlobalHotKeyOperatingMode(_ connection: Int32, _ mode: Int32) -> CGError

// Private API for hardware-accelerated window capture (can capture minimized/other-space windows)
typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

// Match AltTab's exact declaration
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ cid: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>, _ windowCount: UInt32, _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>

// CGS space management
typealias CGSSpaceID = UInt64

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ selector: Int, _ windowIDs: CFArray) -> CFArray

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ displayUUID: CFString) -> CGSSpaceID

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ displayUUID: CFString, _ spaceID: CGSSpaceID)

// Get the main display UUID string (for space switching)
func getMainDisplayUUID() -> CFString? {
    guard let mainDisplay = NSScreen.main,
          let displayID = mainDisplay.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
        return nil
    }
    return CFUUIDCreateString(nil, uuid)
}

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
    let windowID: UInt32  // CGWindowID (may be synthetic for tabs)
    let parentWindowID: UInt32?  // Original window ID if this is a tab (for clustering)
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    var isOnCurrentSpace: Bool = true  // False if window is on another space/desktop
    var tabIndex: Int = 0  // 0-based tab position within window (for tab switching)
    var duplicateIndex: Int = 0  // 0-based index for windows with same title in same app
    var isClusteredTab: Bool = false  // True if this is a non-frontmost tab in a cluster

    // Unique ID for SwiftUI (handles tabs sharing same windowID)
    var id: String {
        "\(windowID)-\(pid)-\(title)-\(duplicateIndex)"
    }

    /// Get the app icon from the running application
    var appIcon: NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.icon
    }

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
    @Published var sidebarResetTrigger: Bool = false  // Toggle to reset sidebar state

    private let cid: Int32
    private var refreshTimer: Timer?
    var isCycling = false  // When true, don't reorder windows during refresh
    var sidebarVisible = false  // When true, preserve window order during refresh

    /// Lock for thread-safe cache access
    private let cacheLock = NSLock()

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
    private var _tabScreenshotCache: [String: NSImage] = [:]

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
        // Get window info
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let cacheKey = tabCacheKey(pid: window.pid, title: window.title)

        // For background tabs, check tabOcrCache first
        if window.parentWindowID != nil {
            if let cached = getTabOcr(key: cacheKey) {
                return cached
            }
            // Background tabs can't be captured - no content available
            return nil
        }

        // Try to capture the window - first via ScreenCaptureKit, then via private API
        var cgImage: CGImage?

        // Try ScreenCaptureKit first (works for most on-screen windows)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                // Use actual window size or cap at reasonable resolution for OCR
                config.width = min(Int(scWindow.frame.width), 1920)
                config.height = min(Int(scWindow.frame.height), 1080)
                config.scalesToFit = false
                config.showsCursor = false

                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch {
            debugLog("OCR: ScreenCaptureKit failed for window \(windowID): \(error)")
        }

        // Fallback: try private API (works for minimized/other-space windows)
        if cgImage == nil {
            debugLog("OCR: Trying private API for window \(windowID)")
            cgImage = captureWindowViaPrivateAPI(windowID: windowID, fullSize: true)
        }

        guard let capturedImage = cgImage else {
            debugLog("OCR: All capture methods failed for window \(windowID)")
            return nil
        }

        // Check if screenshot changed - if not, use cached content
        let newHash = quickImageHash(capturedImage)
        if let oldHash = screenshotHashes[windowID], oldHash == newHash {
            // Screenshot unchanged, return cached content
            if let cached = contentCache[windowID] {
                debugLog("OCR: Screenshot unchanged for window \(windowID), using cache")
                return cached
            }
        }

        // Screenshot changed or no cache, run OCR
        let nsImage = NSImage(cgImage: capturedImage, size: NSSize(width: capturedImage.width, height: capturedImage.height))
        if let text = ocrImage(nsImage) {
            // Update hash for next comparison
            screenshotHashes[windowID] = newHash
            // Also cache by pid+title for when this becomes a background tab
            setTabOcr(key: cacheKey, text: text)
            return text
        }
        return nil
    }

    /// Debug: dump what content we can get from all windows
    func debugContentFetch() {
        debugLog("=== Content fetch debug ===")
        for window in windows {
            if let content = getWindowContent(windowID: window.windowID, pid: window.pid) {
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
            if contentCache[window.windowID] == nil && !contentFailed.contains(window.windowID) {
                return true  // Never indexed
            }
            if window.isOnScreen, let lastTime = lastIndexed[window.windowID],
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
                            if let content = await self.getWindowContentViaOCR(windowID: window.windowID), content.count > 20 {
                                await MainActor.run {
                                    self.contentCache[window.windowID] = content
                                    self.lastIndexed[window.windowID] = Date()
                                }
                                await semaphore.signal()
                                return
                            }
                        }

                        // Fall back to AX API (works for all windows)
                        if let content = self.getWindowContent(windowID: window.windowID, pid: window.pid), content.count > 20 {
                            await MainActor.run {
                                self.contentCache[window.windowID] = content
                                self.lastIndexed[window.windowID] = Date()
                            }
                        } else if !window.isOnScreen {
                            // Only mark as failed if off-screen (on-screen might succeed later)
                            _ = await MainActor.run {
                                self.contentFailed.insert(window.windowID)
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
            guard let content = contentCache[window.windowID] else { continue }

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
                newMatches[window.windowID] = totalScore
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
                        isOnScreen: isOnScreen
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
                            isOnScreen: isActiveTab
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

            // Skip our own windows
            if cgInfo.pid == myPID { continue }

            // Skip excluded apps
            if Self.excludedApps.contains(cgInfo.appName) { continue }

            var windowInfo = WindowInfo(
                windowID: windowID,
                parentWindowID: nil,
                pid: cgInfo.pid,
                appName: cgInfo.appName,
                title: cgInfo.title,
                frame: cgInfo.frame,
                isOnScreen: cgInfo.isOnScreen
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

    func thumbnail(for windowID: UInt32, maxSize: CGSize = CGSize(width: 200, height: 150)) async -> NSImage? {
        debugLog("thumbnail: starting for window \(windowID)")

        // Get window info
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            // Return cached if window no longer exists
            debugLog("thumbnail: window \(windowID) not found, returning cache")
            return thumbnailCache[windowID]
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
            // Background tabs can't be captured directly - fall back to app icon
            if let app = NSRunningApplication(processIdentifier: window.pid),
               let icon = app.icon {
                return icon
            }
            return thumbnailCache[windowID]
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

    func moveWindow(_ windowID: UInt32, to point: CGPoint) {
        var p = point
        _ = SLSMoveWindow(cid, windowID, &p)
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

    /// Switch to the space containing a window
    func switchToSpaceForWindow(_ windowID: UInt32) -> Bool {
        let cid = CGSMainConnectionID()
        guard let displayUUID = getMainDisplayUUID() else {
            debugLog("switchToSpaceForWindow: failed to get display UUID")
            return false
        }

        // Get the space(s) this window belongs to
        let windowArray = [windowID as CFNumber] as CFArray
        let spaces = CGSCopySpacesForWindows(cid, 0x7, windowArray) // 0x7 = all spaces
        guard let spaceIDs = spaces as? [CGSSpaceID], let targetSpace = spaceIDs.first else {
            debugLog("switchToSpaceForWindow: failed to get space for window \(windowID)")
            return false
        }

        // Check if we're already on the target space
        let currentSpace = CGSManagedDisplayGetCurrentSpace(cid, displayUUID)
        if currentSpace == targetSpace {
            debugLog("switchToSpaceForWindow: already on space \(targetSpace)")
            return true
        }

        // Switch to the target space
        debugLog("switchToSpaceForWindow: switching from space \(currentSpace) to \(targetSpace)")
        CGSManagedDisplaySetCurrentSpace(cid, displayUUID, targetSpace)
        return true
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

// MARK: - SwiftUI Views

struct WindowRow: View {
    let window: WindowInfo
    let isSelected: Bool
    let hasContentMatch: Bool
    let thumbnail: NSImage?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Thumbnail with app icon badge
                ZStack(alignment: .bottomTrailing) {
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

                    // App icon badge
                    if let icon = window.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            .offset(x: 4, y: 4)
                    }
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
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.leading, window.isClusteredTab ? 20 : 8)  // Indent clustered tabs
        .padding(.trailing, 8)
        .background(isSelected ? Color.accentColor.opacity(0.4) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var config = AppConfig.shared

    var body: some View {
        Form {
            Section("Activation Shortcut") {
                KeyboardShortcuts.Recorder("Show Winby:", name: .toggleWinby)
                    .help("Press Cmd+Tab here to use it as your shortcut")
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $config.launchAtLogin)
                Toggle("Debug Mode", isOn: $config.debugMode)
                    .help("Show debug controls and log to /tmp/wm_debug.log")
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 250)
        .padding()
    }
}

// MARK: - Onboarding View

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case accessibility
    case screenRecording
    case hotkey
    case launchAtLogin
    case ready
}

struct OnboardingView: View {
    @ObservedObject var config = AppConfig.shared
    @State private var currentStep: OnboardingStep = .welcome
    @State private var permissionCheckTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            ZStack {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    if step == currentStep {
                        stepContent(for: step)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            Spacer()

            // Progress dots
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 520)
        .onAppear {
            startPermissionPolling()
        }
        .onDisappear {
            permissionCheckTimer?.invalidate()
        }
    }

    @ViewBuilder
    func stepContent(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            welcomeStep
        case .accessibility:
            accessibilityStep
        case .screenRecording:
            screenRecordingStep
        case .hotkey:
            hotkeyStep
        case .launchAtLogin:
            launchAtLoginStep
        case .ready:
            readyStep
        }
    }

    // MARK: - Step Views

    var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Welcome to Winby")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("A faster way to switch windows — with search, previews, and content search.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            Button(action: { currentStep = .accessibility }) {
                Text("Get Started")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var accessibilityStep: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Image(systemName: "accessibility")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                if config.hasAccessibilityPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                        .offset(x: 36, y: 28)
                }
            }

            Text("Accessibility Access")
                .font(.title)
                .fontWeight(.bold)

            Text("Winby needs Accessibility access to manage windows and respond to your keyboard shortcut.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            if config.hasAccessibilityPermission {
                Button(action: { currentStep = .screenRecording }) {
                    Text("Continue")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: { config.openAccessibilitySettings() }) {
                    Text("Open System Settings")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Grant access, then return here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var screenRecordingStep: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Image(systemName: "camera.metering.spot")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                if config.hasScreenRecordingPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                        .offset(x: 36, y: 28)
                }
            }

            Text("Screen Recording")
                .font(.title)
                .fontWeight(.bold)

            Text("Screen Recording lets Winby search by what's visible in your windows.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            if config.hasScreenRecordingPermission {
                Button(action: { currentStep = .hotkey }) {
                    Text("Continue")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: { config.openScreenRecordingSettings() }) {
                    Text("Open System Settings")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Grant access, then return here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button(action: { currentStep = .accessibility }) {
                    Text("Back")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var hotkeyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Choose Your Hotkey")
                .font(.title)
                .fontWeight(.bold)

            Text("Pick a keyboard shortcut to activate Winby.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            KeyboardShortcuts.Recorder("", name: .toggleWinby)
                .padding(.vertical, 8)

            Text("Tip: You can use Cmd+Tab, but it requires granting Accessibility permission again after setting it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer()

            Button(action: { currentStep = .launchAtLogin }) {
                Text("Continue")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: { currentStep = .screenRecording }) {
                Text("Back")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var launchAtLoginStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "power")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Launch at Login")
                .font(.title)
                .fontWeight(.bold)

            Text("Start Winby automatically when you log in.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Toggle("Launch at Login", isOn: $config.launchAtLogin)
                .toggleStyle(.switch)
                .labelsHidden()
                .padding(.vertical, 8)

            Spacer()

            Button(action: { currentStep = .ready }) {
                Text("Continue")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: { currentStep = .hotkey }) {
                Text("Back")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var readyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Press \(config.hotkeyDescription) to open Winby anytime.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            Button(action: {
                config.hasCompletedOnboarding = true
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.hideOnboardingWindow()
                }
            }) {
                Text("Start Using Winby")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    // MARK: - Permission Polling

    func startPermissionPolling() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // Auto-advance when permissions are granted
            if currentStep == .accessibility && config.hasAccessibilityPermission {
                withAnimation {
                    currentStep = .screenRecording
                }
            } else if currentStep == .screenRecording && config.hasScreenRecordingPermission {
                withAnimation {
                    currentStep = .hotkey
                }
            }
        }
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
        // Trim spaces - they're used as term separators, not search characters
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        if trimmedSearch.isEmpty {
            return manager.windows
        }
        // Fuzzy match and sort by score (including content matches)
        let query = trimmedSearch.lowercased()
        let scored = manager.windows.compactMap { window -> (WindowInfo, Int)? in
            let titleScore = fuzzyMatch(query: query, in: window.displayTitle.lowercased())
            let appScore = fuzzyMatch(query: query, in: window.appName.lowercased())
            let contentScore = manager.contentMatches[window.windowID] ?? 0

            // Window matches if title/app matches OR content matches
            let titleAppScore = max(titleScore, appScore)
            if titleAppScore > 0 || contentScore > 0 {
                return (window, titleAppScore + contentScore)
            }
            return nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Windows on the current space
    var currentSpaceWindows: [WindowInfo] {
        filteredWindows.filter { $0.isOnCurrentSpace }
    }

    /// Windows on other spaces
    var otherSpaceWindows: [WindowInfo] {
        filteredWindows.filter { !$0.isOnCurrentSpace }
    }

    /// Trigger debounced content search
    func triggerContentSearch() {
        contentSearchTask?.cancel()
        contentSearchTask = Task {
            // Debounce: wait 300ms before searching
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
            guard !trimmedSearch.isEmpty else { return }

            await MainActor.run { isSearchingContent = true }
            await manager.searchContent(query: trimmedSearch)
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
        // Current space windows first, then other spaces
        currentSpaceWindows + otherSpaceWindows
    }

    func selectNext() {
        let list = flatWindowList
        guard !list.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = list.firstIndex(where: { $0.windowID == current }) {
            let nextIdx = min(idx + 1, list.count - 1)
            manager.selectedWindowID = list[nextIdx].windowID
        } else {
            manager.selectedWindowID = list[0].windowID
        }
    }

    func selectPrevious() {
        let list = flatWindowList
        guard !list.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = list.firstIndex(where: { $0.windowID == current }) {
            let prevIdx = max(idx - 1, 0)
            manager.selectedWindowID = list[prevIdx].windowID
        } else {
            manager.selectedWindowID = list[0].windowID
        }
    }

    func activateSelected() {
        // Use selected window, or first visible window if nothing selected
        let windowID = manager.selectedWindowID ?? filteredWindows.first?.windowID

        if let windowID = windowID {
            manager.bringToFront(windowID)
            searchText = ""
            // Mark that we selected a window (so focus isn't restored to previous app)
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.didSelectWindow = true
                appDelegate.hideSidebar()
            }
        }
    }

    /// Update debug content when selection changes
    func updateDebugContent() {
        guard showDebugPanel, let windowID = manager.selectedWindowID,
              let window = manager.windows.first(where: { $0.windowID == windowID }) else {
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
                        // Current space windows
                        ForEach(currentSpaceWindows) { window in
                            WindowRow(
                                window: window,
                                isSelected: manager.selectedWindowID == window.windowID,
                                hasContentMatch: manager.contentMatches[window.windowID] != nil,
                                thumbnail: thumbnails[window.windowID],
                                onSelect: {
                                    manager.selectedWindowID = window.windowID
                                    manager.bringToFront(window.windowID)
                                    searchText = ""
                                    // Mark selection and hide sidebar
                                    if let appDelegate = NSApp.delegate as? AppDelegate {
                                        appDelegate.didSelectWindow = true
                                        appDelegate.hideSidebar()
                                    }
                                }
                            )
                            .id(window.id)  // Use String id for SwiftUI identity
                        }

                        // Other spaces section (if any)
                        if !otherSpaceWindows.isEmpty {
                            HStack {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 1)
                                Text("Other Spaces")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)

                            ForEach(otherSpaceWindows) { window in
                                WindowRow(
                                    window: window,
                                    isSelected: manager.selectedWindowID == window.windowID,
                                    hasContentMatch: manager.contentMatches[window.windowID] != nil,
                                    thumbnail: thumbnails[window.windowID],
                                    onSelect: {
                                        manager.selectedWindowID = window.windowID
                                        manager.bringToFront(window.windowID)
                                        searchText = ""
                                        // Mark selection and hide sidebar
                                        if let appDelegate = NSApp.delegate as? AppDelegate {
                                            appDelegate.didSelectWindow = true
                                            appDelegate.hideSidebar()
                                        }
                                    }
                                )
                                .id(window.id)
                                .opacity(0.7)  // Slightly dimmed to indicate different space
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 50)  // Extra space so last item can scroll into view
                }
                .onChange(of: manager.selectedWindowID) { _, newValue in
                    if let windowID = newValue,
                       let window = flatWindowList.first(where: { $0.windowID == windowID }) {
                        // Use bottom anchor when near end of list for better visibility
                        let isNearEnd = flatWindowList.last?.windowID == windowID
                        withAnimation {
                            proxy.scrollTo(window.id, anchor: isNearEnd ? .bottom : .center)
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
            var newThumbnails = thumbnails

            // Get all SC windows ONCE (expensive call)
            let scWindows: [SCWindow]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                scWindows = content.windows
                debugLog("loadThumbnails: got \(scWindows.count) SCWindows")
            } catch {
                debugLog("loadThumbnails: SCShareableContent failed: \(error)")
                scWindows = []
            }

            // Build lookup map
            let scWindowMap = Dictionary(uniqueKeysWithValues: scWindows.map { ($0.windowID, $0) })

            // Process windows in parallel with limited concurrency
            await withTaskGroup(of: (UInt32, NSImage?).self) { group in
                for window in manager.windows {
                    let isBackgroundTab = window.parentWindowID != nil
                    // Skip if we already have a thumbnail for background tabs
                    if isBackgroundTab && newThumbnails[window.windowID] != nil {
                        continue
                    }

                    group.addTask {
                        let thumb = await self.captureThumbnail(
                            window: window,
                            scWindow: scWindowMap[window.windowID],
                            maxSize: CGSize(width: 200, height: 150)
                        )
                        return (window.windowID, thumb)
                    }
                }

                for await (windowID, thumb) in group {
                    if let thumb = thumb {
                        newThumbnails[windowID] = thumb
                    }
                }
            }

            // Keep thumbnails for current windows
            let currentIDs = Set(manager.windows.map { $0.windowID })
            newThumbnails = newThumbnails.filter { currentIDs.contains($0.key) }

            await MainActor.run {
                thumbnails = newThumbnails
            }
        }
    }

    /// Capture a single thumbnail using provided SCWindow (avoids repeated SCShareableContent calls)
    /// Also caches the full-size image for instant preview loading
    func captureThumbnail(window: WindowInfo, scWindow: SCWindow?, maxSize: CGSize) async -> NSImage? {
        // For background tabs, check tab screenshot cache first
        if window.parentWindowID != nil {
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            if let cached = manager.getTabScreenshot(key: cacheKey) {
                return cached
            }
            // Background tabs can't be captured directly - fall back to app icon
            if let app = NSRunningApplication(processIdentifier: window.pid),
               let icon = app.icon {
                return icon
            }
            return nil
        }

        var fullImage: NSImage?

        // Try ScreenCaptureKit if we have an SCWindow - capture at window's actual size
        if let scWindow = scWindow {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                // Capture at window's actual resolution (2x for retina)
                let windowSize = scWindow.frame.size
                config.width = Int(windowSize.width * 2)
                config.height = Int(windowSize.height * 2)
                config.scalesToFit = false
                config.showsCursor = false

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                fullImage = NSImage(cgImage: cgImage, size: windowSize)
            } catch {
                // Fall through to private API
            }
        }

        // Fallback: try private API at full size
        if fullImage == nil {
            if let cgImage = manager.captureWindowViaPrivateAPI(windowID: window.windowID, fullSize: true) {
                let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                fullImage = NSImage(cgImage: cgImage, size: size)
            }
        }

        // Cache full image for preview panel and tab screenshot cache
        if let fullImage = fullImage {
            manager.setFullImage(for: window.windowID, image: fullImage)

            // Also cache in tab screenshot cache for when this becomes a background tab
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            manager.setTabScreenshot(key: cacheKey, image: fullImage)

            // Create thumbnail from full image
            let fullSize = fullImage.size
            let scale = min(maxSize.width / fullSize.width, maxSize.height / fullSize.height)
            let scaledSize = CGSize(width: fullSize.width * scale, height: fullSize.height * scale)
            let thumbnail = NSImage(size: scaledSize)
            thumbnail.lockFocus()
            fullImage.draw(in: NSRect(origin: .zero, size: scaledSize))
            thumbnail.unlockFocus()
            return thumbnail
        }

        // Final fallback: app icon
        if let app = NSRunningApplication(processIdentifier: window.pid),
           let icon = app.icon {
            return icon
        }

        return nil
    }
}

// MARK: - Preview Panel View

struct PreviewPanelView: View {
    @ObservedObject var manager = WindowManager.shared
    @State private var previewImage: NSImage?
    @State private var loadingTask: Task<Void, Never>?

    private let padding: CGFloat = 12

    var body: some View {
        ZStack {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(padding)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Focus the selected window
                        if let windowID = manager.selectedWindowID {
                            manager.bringToFront(windowID)
                            if let appDelegate = NSApp.delegate as? AppDelegate {
                                appDelegate.didSelectWindow = true
                                appDelegate.hideSidebar()
                            }
                        }
                    }
            } else {
                // Show app icon as placeholder while loading
                if let windowID = manager.selectedWindowID,
                   let window = manager.windows.first(where: { $0.windowID == windowID }),
                   let app = NSRunningApplication(processIdentifier: window.pid),
                   let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                        .opacity(0.5)
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: manager.selectedWindowID) { _, newValue in
            loadPreview(for: newValue)
        }
        .onAppear {
            loadPreview(for: manager.selectedWindowID)
        }
    }

    private func resizeWindowToFit(_ image: NSImage?) {
        debugLog("resizeWindowToFit called, image=\(image != nil)")
        guard let image = image,
              let appDelegate = NSApp.delegate as? AppDelegate,
              let window = appDelegate.previewWindow else {
            debugLog("resizeWindowToFit: guard failed - appDelegate=\(NSApp.delegate != nil), previewWindow=\((NSApp.delegate as? AppDelegate)?.previewWindow != nil)")
            return
        }

        let imageSize = image.size
        debugLog("resizeWindowToFit: imageSize=\(imageSize)")
        guard imageSize.width > 0 && imageSize.height > 0 else { return }

        // Calculate target size - fit within screen with max dimensions
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let maxWidth = screen.visibleFrame.width * 0.6
        let maxHeight = screen.visibleFrame.height * 0.7

        let imageAspect = imageSize.width / imageSize.height
        var targetWidth: CGFloat
        var targetHeight: CGFloat

        if imageAspect > maxWidth / maxHeight {
            // Image is wider - constrain by width
            targetWidth = min(imageSize.width, maxWidth)
            targetHeight = targetWidth / imageAspect
        } else {
            // Image is taller - constrain by height
            targetHeight = min(imageSize.height, maxHeight)
            targetWidth = targetHeight * imageAspect
        }

        // Add padding
        targetWidth += padding * 2
        targetHeight += padding * 2

        // Resize window, keeping center position
        let currentFrame = window.frame
        let newFrame = NSRect(
            x: currentFrame.midX - targetWidth / 2,
            y: currentFrame.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        debugLog("resizeWindowToFit: currentFrame=\(currentFrame), newFrame=\(newFrame)")
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func loadPreview(for windowID: UInt32?) {
        // Cancel any in-progress load
        loadingTask?.cancel()

        guard let windowID = windowID else {
            previewImage = nil
            return
        }

        // Clear immediately if we don't have a cached image
        // This prevents showing stale preview for windows without screenshots
        // Check both fullImageCache and tabScreenshotCache
        var hasCachedImage = manager.getFullImage(for: windowID) != nil
        if !hasCachedImage, let window = manager.windows.first(where: { $0.windowID == windowID }) {
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            hasCachedImage = manager.getTabScreenshot(key: cacheKey) != nil
        }
        if !hasCachedImage {
            previewImage = nil
        }

        loadingTask = Task {
            let image = await captureWindowImage(windowID: windowID)
            if !Task.isCancelled {
                await MainActor.run {
                    previewImage = image  // Will be nil if capture failed
                    resizeWindowToFit(image)
                }
            }
        }
    }

    private func captureWindowImage(windowID: UInt32) async -> NSImage? {
        // Check full image cache first - populated during thumbnail loading
        if let cached = manager.getFullImage(for: windowID) {
            return cached
        }

        // For background tabs, check tab screenshot cache
        if let window = manager.windows.first(where: { $0.windowID == windowID }),
           window.parentWindowID != nil {
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            if let cached = manager.getTabScreenshot(key: cacheKey) {
                return cached
            }
            // Background tabs can't be captured - no fallback
            return nil
        }

        // Try private API - it's fast and works for most windows
        if let cgImage = manager.captureWindowViaPrivateAPI(windowID: windowID, fullSize: true) {
            let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            manager.setFullImage(for: windowID, image: image)
            return image
        }

        return nil
    }
}

// MARK: - App Delegate

// Global reference for CGEventTap callback
private var globalAppDelegate: AppDelegate?

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var previewWindow: NSWindow?
    var statusItem: NSStatusItem?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // Event tap for Cmd+Tab interception
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Carbon hotkey for Cmd+Tab (bypasses system handler)
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?

    // Track if we're in tab-cycling mode (second+ Tab press while Cmd held)
    var isTabCycling = false
    // Temporarily set when raising windows to prevent auto-hide
    var isRaisingWindow = false

    // Local event monitor for catching hotkey when app has focus
    private var localEventMonitor: Any?

    // Global click monitor for dismissing on click outside
    private var globalClickMonitor: Any?

    // Track the previously focused app to restore on dismiss without selection
    private var previouslyFocusedApp: NSRunningApplication?
    // Track if a window was selected (to know whether to restore focus)
    var didSelectWindow = false

    // Onboarding window for first-run experience
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create floating panel window (always needed)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: [.titled, .fullSizeContentView, .hudWindow],
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

        // Prevent focus loss to other windows when sidebar is visible
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self = self, self.window.isVisible else { return }
            // Immediately reclaim focus if sidebar loses it while visible
            DispatchQueue.main.async {
                guard self.window.isVisible && !self.window.isKeyWindow else { return }

                let keyWindow = NSApp.keyWindow
                debugLog("Sidebar resigned key, new key window: \(keyWindow?.title ?? "none")")

                // Don't reclaim if settings has focus (preview is .nonactivatingPanel so won't become key)
                if keyWindow == self.settingsWindow {
                    return
                }

                // Some other window stole focus - reclaim it
                debugLog("Reclaiming focus for sidebar")
                self.window.makeKey()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

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
        panel.level = .popUpMenu  // Higher than .floating to stay above activated apps
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Start hidden - user activates with hotkey
        panel.orderOut(nil)

        // Create preview panel (centered on screen, shows large window preview)
        setupPreviewWindow()

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

        // Check if this is first run - show onboarding if not completed
        if !AppConfig.shared.hasCompletedOnboarding {
            showOnboardingWindow()
        } else {
            // Already onboarded - set up hotkeys and verify permissions
            setupGlobalHotkey()
            requestAccessibilityPermissions()

            // Request screen capture permission if not granted
            if !CGPreflightScreenCaptureAccess() {
                debugLog("Requesting screen capture permission...")
                let granted = CGRequestScreenCaptureAccess()
                debugLog("Screen capture permission granted: \(granted)")
            }
        }
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

    func setupPreviewWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Calculate preview size (leave room for sidebar and margins)
        let sidebarWidth: CGFloat = 280
        let margin: CGFloat = 40
        let availableWidth = screenFrame.width - sidebarWidth - margin * 2
        let availableHeight = screenFrame.height - margin * 2
        let previewWidth = min(availableWidth, availableHeight * 16 / 9)  // 16:9 aspect ratio max
        let previewHeight = previewWidth * 9 / 16

        let previewPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewWindow = previewPanel

        previewPanel.isMovableByWindowBackground = true
        previewPanel.becomesKeyOnlyIfNeeded = true
        previewPanel.hidesOnDeactivate = false
        previewPanel.isOpaque = false
        previewPanel.backgroundColor = .clear
        previewPanel.hasShadow = true
        previewPanel.level = .popUpMenu
        previewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        previewPanel.minSize = NSSize(width: 200, height: 150)

        // Persist window position/size across restarts
        previewPanel.setFrameAutosaveName("WinbyPreviewWindow")

        // Add visual effect background
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: PreviewPanelView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        previewPanel.contentView = visualEffect

        // Only set default position if no saved frame exists
        if !previewPanel.setFrameUsingName("WinbyPreviewWindow") {
            // Center the preview panel (accounting for sidebar on left)
            let centerX = screenFrame.origin.x + sidebarWidth + (screenFrame.width - sidebarWidth - previewWidth) / 2
            let centerY = screenFrame.origin.y + (screenFrame.height - previewHeight) / 2
            previewPanel.setFrame(
                NSRect(x: centerX, y: centerY, width: previewWidth, height: previewHeight),
                display: true
            )
        }

        previewPanel.orderOut(nil)
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

    func showOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.center()

            // Add visual effect background
            let visualEffect = NSVisualEffectView()
            visualEffect.material = .windowBackground
            visualEffect.state = .active
            visualEffect.blendingMode = .behindWindow

            let hostingView = NSHostingView(rootView: OnboardingView())
            hostingView.translatesAutoresizingMaskIntoConstraints = false

            visualEffect.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
            ])

            window.contentView = visualEffect
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideOnboardingWindow() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil

        // After onboarding, set up the hotkey and other runtime things
        setupGlobalHotkey()
    }

    @objc func debugDumpContent() {
        WindowManager.shared.debugContentFetch()
        debugLog("Content dump written to /tmp/wm_debug.log")
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        // Don't auto-hide while sidebar is visible - we raise other windows during preview
        // Only hide on explicit dismiss (Escape, Return, clicking a window, etc.)
    }

    @objc func toggleSidebar() {
        if window.isVisible {
            hideSidebar()
        } else {
            showSidebar()
        }
    }

    /// Save the currently focused app to restore later if Winby is dismissed without selection
    func savePreviousFocus() {
        // Get frontmost app that isn't Winby
        let frontmost = NSWorkspace.shared.frontmostApplication
        let winbyPID = ProcessInfo.processInfo.processIdentifier

        if let app = frontmost, app.processIdentifier != winbyPID {
            previouslyFocusedApp = app
            debugLog("Saved previous app: \(app.localizedName ?? "unknown") (pid: \(app.processIdentifier))")
        } else {
            debugLog("Could not find non-Winby frontmost app (frontmost is \(frontmost?.localizedName ?? "none"))")
        }
        didSelectWindow = false
    }

    func showSidebar() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Disable system hotkeys (like Cmd+Tab) while our switcher is active
        _ = CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 1)  // 1 = disable

        // Position at left edge of screen
        window.setFrame(
            NSRect(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y,
                width: 280,
                height: screenFrame.height
            ),
            display: false
        )

        // Select the current window (first in list) when sidebar opens
        let manager = WindowManager.shared
        manager.sidebarVisible = true
        if let firstWindow = manager.windows.first {
            manager.selectedWindowID = firstWindow.windowID
        }

        // Fade in
        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        // Show preview panel with fade in
        if let preview = previewWindow {
            preview.alphaValue = 0
            preview.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                preview.animator().alphaValue = 1
            }
        }

        // Add global click monitor to dismiss when clicking outside both windows
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return }

            let screenLocation = NSEvent.mouseLocation

            // Check if click is inside sidebar window
            if self.window.frame.contains(screenLocation) {
                return
            }

            // Check if click is inside preview window
            if let preview = self.previewWindow, preview.frame.contains(screenLocation) {
                return
            }

            // Click was outside both windows - dismiss
            self.hideSidebar()
        }
    }

    func hideSidebar() {
        // Remove global click monitor
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

        // Clear cycling state
        isTabCycling = false
        WindowManager.shared.isCycling = false
        WindowManager.shared.sidebarVisible = false

        // Re-enable system hotkeys
        _ = CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 0)  // 0 = enable

        // Restore focus to previous app if no window was selected
        if !didSelectWindow, let previousApp = previouslyFocusedApp {
            debugLog("Restoring focus to: \(previousApp.localizedName ?? "unknown") (pid: \(previousApp.processIdentifier))")
            previousApp.activate()

            // Also try to bring the frontmost window to front using AX
            let appElement = AXUIElementCreateApplication(previousApp.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement],
               let frontWindow = windows.first {
                AXUIElementPerformAction(frontWindow, kAXRaiseAction as CFString)
                debugLog("Raised previous app's front window via AX")
            }
        } else if !didSelectWindow {
            debugLog("No previous app to restore focus to")
        } else {
            debugLog("Window was selected, not restoring previous focus")
        }
        previouslyFocusedApp = nil

        // Reset sidebar state
        WindowManager.shared.sidebarResetTrigger.toggle()

        // Hide preview panel with fade out
        if let preview = previewWindow {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                preview.animator().alphaValue = 0
            }, completionHandler: {
                preview.orderOut(nil)
            })
        }

        // Fade out sidebar
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.window.animator().alphaValue = 0
        }, completionHandler: {
            self.window.orderOut(nil)
        })
    }

    @objc func refreshWindows() {
        WindowManager.shared.refresh()
    }

    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("Accessibility permissions required for full functionality")
        }
    }

    /// Register Cmd+Tab as a Carbon hotkey (bypasses system Dock handler)
    func setupCarbonHotkey() {
        // Only register if Cmd+Tab is the configured shortcut
        // Called from main thread, use assumeIsolated
        let isCmdTab = MainActor.assumeIsolated { AppConfig.shared.isCmdTabShortcut }
        guard isCmdTab else {
            debugLog("Cmd+Tab not configured, skipping Carbon hotkey")
            return
        }

        // Unregister existing hotkey if any
        if let existingRef = carbonHotKeyRef {
            UnregisterEventHotKey(existingRef)
            carbonHotKeyRef = nil
        }

        // Define the hotkey: Cmd+Tab
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x57494E42)  // "WINB"
        hotKeyID.id = 1

        // Tab = 48, Cmd = cmdKey
        let keyCode: UInt32 = 48
        let modifiers: UInt32 = UInt32(cmdKey)

        // Register the hotkey
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            carbonHotKeyRef = ref
            debugLog("Carbon Cmd+Tab hotkey registered successfully")

            // Install event handler for the hotkey
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            let handlerCallback: EventHandlerUPP = { (_, event, userData) -> OSStatus in
                guard let appDelegate = globalAppDelegate else { return noErr }

                DispatchQueue.main.async {
                    // Check if settings window is focused - don't handle if so
                    if appDelegate.settingsWindow?.isKeyWindow == true {
                        return
                    }

                    if appDelegate.window.isVisible {
                        // Second+ press: enter cycling mode
                        appDelegate.isTabCycling = true
                        WindowManager.shared.isCycling = true
                        appDelegate.selectNextWindow()
                    } else {
                        // First press: save focus and show sidebar
                        // showSidebar() selects the current window (index 0)
                        appDelegate.savePreviousFocus()
                        appDelegate.showSidebar()
                    }
                }
                return noErr
            }

            var handlerRef: EventHandlerRef?
            InstallEventHandler(
                GetApplicationEventTarget(),
                handlerCallback,
                1,
                &eventType,
                nil,
                &handlerRef
            )
            carbonEventHandler = handlerRef
        } else {
            debugLog("Failed to register Carbon hotkey: \(status)")
        }
    }

    func setupGlobalHotkey() {
        // 1. Set up customizable hotkey via KeyboardShortcuts
        KeyboardShortcuts.onKeyDown(for: .toggleWinby) { [weak self] in
            guard let self = self else { return }

            // KeyboardShortcuts callbacks run on main thread
            MainActor.assumeIsolated {
                // If Cmd+Tab is the configured shortcut, Carbon hotkey handles it instead
                if AppConfig.shared.isCmdTabShortcut {
                    return
                }

                // Check if shift is held for reverse direction
                let goBackward = NSEvent.modifierFlags.contains(.shift)

                if self.window.isVisible {
                    // Second+ press: enter cycling mode
                    self.isTabCycling = true
                    WindowManager.shared.isCycling = true
                    if goBackward {
                        self.selectPreviousWindow()
                    } else {
                        self.selectNextWindow()
                    }
                } else {
                    // First press: save focus and show sidebar
                    // showSidebar() selects the current window (index 0)
                    self.savePreviousFocus()
                    self.showSidebar()
                }
            }
        }

        // 2. Register Carbon hotkey for Cmd+Tab (this takes priority over the system)
        setupCarbonHotkey()

        // 3. Set up CGEventTap to handle Cmd release and Cmd+Shift+Tab
        globalAppDelegate = self

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                return globalAppDelegate?.handleEventTap(proxy: proxy, type: type, event: event) ?? Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            debugLog("Failed to create event tap for Cmd+Tab - accessibility permissions may be needed")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            debugLog("CGEventTap installed successfully for Cmd+Tab")
        }

        // 4. Set up local event monitor to catch hotkey when app has focus
        // This handles the case where the global monitor doesn't fire because the app is active
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Only intercept when sidebar is visible
            guard self.window.isVisible else { return event }

            let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])

            // Check for Cmd+Enter to fullscreen selected window
            if event.keyCode == 36 && eventModifiers == .command {  // 36 = Return key
                if let windowID = WindowManager.shared.selectedWindowID {
                    WindowManager.shared.bringToFront(windowID)
                    WindowManager.shared.toggleFullscreen(windowID)
                    self.didSelectWindow = true
                    self.hideSidebar()
                    return nil  // Consume the event
                }
            }

            // Check if this matches the configured hotkey
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleWinby) {
                // Compare key and modifiers
                if let key = shortcut.key,
                   event.keyCode == key.rawValue,
                   eventModifiers == shortcut.modifiers {
                    // Hotkey pressed while sidebar visible - hide it
                    self.hideSidebar()
                    return nil  // Consume the event
                }
            }

            return event
        }
    }

    func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Check if Cmd+Tab is configured as the shortcut
        // Event tap callback runs on main thread, so use assumeIsolated to avoid deadlock
        let (shouldInterceptCmdTab, settingsIsKey): (Bool, Bool)
        if Thread.isMainThread {
            shouldInterceptCmdTab = MainActor.assumeIsolated {
                AppConfig.shared.isCmdTabShortcut
            }
            settingsIsKey = settingsWindow?.isKeyWindow ?? false
        } else {
            shouldInterceptCmdTab = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    AppConfig.shared.isCmdTabShortcut
                }
            }
            settingsIsKey = settingsWindow?.isKeyWindow ?? false
        }

        // If settings window is focused, intercept Cmd+Tab but post synthetic event for recorder
        if settingsIsKey && type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isTab = keyCode == 48
            let isCmd = flags.contains(.maskCommand)

            if isTab && isCmd {
                // Post synthetic key event to the app so recorder can capture it
                DispatchQueue.main.async {
                    if let syntheticEvent = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0,
                        context: nil,
                        characters: "\t",
                        charactersIgnoringModifiers: "\t",
                        isARepeat: false,
                        keyCode: 48
                    ) {
                        NSApp.sendEvent(syntheticEvent)
                    }
                }
                // Block system Cmd+Tab
                return nil
            }
        }

        // Handle modifier key changes (detect when Cmd is released)
        if type == .flagsChanged {
            let flags = event.flags

            // If Cmd is released while in cycling mode (second+ Tab was pressed), activate
            if isTabCycling && !flags.contains(.maskCommand) {
                DispatchQueue.main.async { [weak self] in
                    self?.activateSelectedAndHide()
                }
            }
            // If Cmd is released after just one Tab (not cycling), window stays open
            return Unmanaged.passRetained(event)
        }

        // Handle key down events
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // Tab key = 48
            let isTab = keyCode == 48
            let isCmd = flags.contains(.maskCommand)
            let isShift = flags.contains(.maskShift)
            let hasOtherModifiers = flags.contains(.maskAlternate) || flags.contains(.maskControl)

            // Only intercept Cmd+Tab (or Cmd+Shift+Tab) if it's the configured shortcut
            // and no other modifiers are pressed
            if isTab && isCmd && !hasOtherModifiers && shouldInterceptCmdTab {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    if !self.window.isVisible {
                        // First shortcut press: show sidebar
                        // showSidebar() selects the current window (index 0)
                        // Do NOT enter cycling mode yet - release will keep window open
                        self.showSidebar()
                    } else {
                        // Second+ shortcut press while visible: NOW enter cycling mode
                        self.isTabCycling = true
                        WindowManager.shared.isCycling = true
                        if isShift {
                            self.selectPreviousWindow()
                        } else {
                            self.selectNextWindow()
                        }
                    }
                }
                // Consume the event (don't pass to system)
                return nil
            }
        }

        // Pass other events through
        return Unmanaged.passRetained(event)
    }

    func selectNextWindow() {
        let manager = WindowManager.shared
        let windows = manager.windows

        guard !windows.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = windows.firstIndex(where: { $0.windowID == current }) {
            let nextIdx = (idx + 1) % windows.count
            manager.selectedWindowID = windows[nextIdx].windowID
        } else {
            // First invocation: select window #2 (index 1) since #1 is the current window
            // Just like standard Cmd+Tab behavior
            let idx = windows.count > 1 ? 1 : 0
            manager.selectedWindowID = windows[idx].windowID
        }
    }

    func selectPreviousWindow() {
        let manager = WindowManager.shared
        let windows = manager.windows

        guard !windows.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = windows.firstIndex(where: { $0.windowID == current }) {
            let prevIdx = idx > 0 ? idx - 1 : windows.count - 1
            manager.selectedWindowID = windows[prevIdx].windowID
        } else {
            // First invocation going backward: select last window
            manager.selectedWindowID = windows[windows.count - 1].windowID
        }
    }

    func activateSelectedAndHide() {
        let manager = WindowManager.shared
        if let windowID = manager.selectedWindowID {
            manager.bringToFront(windowID)
            didSelectWindow = true
        }
        hideSidebar()
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
