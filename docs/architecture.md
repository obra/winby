# Winby Architecture

Overview of Winby's architecture and key components.

## Overview

Winby is a macOS menu bar app that provides fast window switching with:
- Keyboard-driven sidebar showing all windows
- Live preview panel showing selected window screenshot
- Search by window title, app name, or visible content (OCR)
- Tab support for Terminal, Safari, Chrome, Ghostty, etc.
- Cross-space window switching

## File Structure

```
Sources/Winby/
└── main.swift        # Single-file app (~4500 lines)

docs/
├── index.html        # Landing page (GitHub Pages)
├── tab-switching.md  # Tab switching documentation
├── window-management.md
├── space-switching.md
├── screenshot-capture.md
└── architecture.md   # This file
```

## Key Components

### WindowManager

Singleton class managing all window state:

```swift
class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var windows: [WindowInfo] = []
    @Published var selectedWindowID: UInt32?

    // Caches
    var thumbnailCache: [UInt32: NSImage]
    var fullImageCache: [UInt32: NSImage]
    var tabScreenshotCache: [String: NSImage]  // pid:title -> image
    var contentCache: [UInt32: String]         // OCR results

    // State flags
    var isCycling = false        // Cmd+Tab cycling mode
    var sidebarVisible = false   // Preserve order while visible
}
```

### WindowInfo

Data model for a single window:

```swift
struct WindowInfo: Identifiable {
    let windowID: UInt32
    var parentWindowID: UInt32?  // Non-nil for background tabs
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    var isOnCurrentSpace: Bool
    var tabIndex: Int            // Position in tab bar (for switching)

    // Computed ID for SwiftUI (handles tabs sharing windowID)
    var id: String {
        if let parent = parentWindowID {
            return "\(parent)-\(tabIndex)-\(title.hashValue)"
        }
        return "\(windowID)"
    }
}
```

### AppDelegate

Manages windows, hotkeys, and app lifecycle:

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!           // Sidebar panel
    var previewWindow: NSWindow?    // Screenshot preview
    var statusItem: NSStatusItem?   // Menu bar icon

    // Event handling
    private var eventTap: CFMachPort?
    private var localEventMonitor: Any?
    private var globalClickMonitor: Any?

    // State
    var isTabCycling = false
    var didSelectWindow = false
    var previouslyFocusedApp: NSRunningApplication?
}
```

### SwiftUI Views

- **SidebarView** - Main window list with search
- **WindowRow** - Individual window row with thumbnail
- **PreviewPanelView** - Large screenshot preview

## Window Enumeration Flow

```
1. Get current space windows (CGWindowListCopyWindowInfo)
   ↓
2. For each running app:
   a. Get AX windows (AXUIElementCopyAttributeValue)
   b. For each window, enumerate tabs
   c. Add to windows list with isOnCurrentSpace flag
   ↓
3. Add other-space windows from CGWindowList
   - Skip duplicates (title-based matching)
   ↓
4. Sort: current space first, then by app, then by recency
```

## Tab Handling

### Identification

Tabs are identified by `parentWindowID`:
- `nil` = regular window or active tab
- non-nil = background tab (parent is the window containing the tab)

### Enumeration

```
1. Find AXTabGroup in window hierarchy
2. Check kAXTabsAttribute (standard tabs)
3. If empty, check for AXRadioButton children (Terminal, Ghostty)
4. Get title and selected state for each tab
```

### Switching

```
1. If Terminal/Ghostty: Direct AX click on radio button
2. If Safari/Chrome: AppleScript with native tab API
3. If other app: System Events AppleScript
4. Match by title, not index (order is unreliable)
```

## Screenshot Flow

```
1. Get SCShareableContent (expensive, cached)
   ↓
2. For each window:
   a. If background tab → check tabScreenshotCache
   b. If visible → capture via ScreenCaptureKit
   c. If other space → capture via private API
   ↓
3. Cache in appropriate cache:
   - thumbnailCache (by windowID)
   - fullImageCache (by windowID)
   - tabScreenshotCache (by pid:title)
```

## Focus/Space Switch Flow

```
1. If background tab on current space:
   a. Click the tab via AX
   b. Done (tab click handles focus)

2. If window on other space:
   a. If background tab, switch tab first
   b. SLPSSetFrontProcessWithOptions (userGenerated mode)
   c. makeKeyWindow (binary protocol to WindowServer)
   d. Find AXUIElement via brute-force token probing
   e. AXRaise (triggers space switch)
```

## Hotkey Handling

### Configured Hotkey (e.g., Cmd+Shift+Space)

```swift
// Using KeyboardShortcuts library
KeyboardShortcuts.onKeyDown(for: .showWindowSwitcher) {
    appDelegate.toggleSidebar()
}
```

### Cmd+Tab Interception

```swift
// Disable system hotkeys while switcher is active
CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 1)

// Handle Tab presses for cycling
localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.keyCode == 48 {  // Tab
        if event.modifierFlags.contains(.command) {
            WindowManager.shared.selectNextWindow()
        } else if event.modifierFlags.contains(.shift) {
            WindowManager.shared.selectPreviousWindow()
        }
        return nil  // Consume event
    }
    return event
}
```

## Caching Strategy

| Cache | Key | Purpose |
|-------|-----|---------|
| thumbnailCache | windowID | Sidebar thumbnails |
| fullImageCache | windowID | Preview panel |
| tabScreenshotCache | "pid:title" | Background tab screenshots |
| contentCache | windowID | OCR text results |
| tabOcrCache | "pid:title" | Background tab OCR |
| browserTabCache | bundleId | Safari/Chrome tab lists (2s TTL) |

## Threading Model

- **Main thread**: UI updates, SwiftUI
- **Background tasks**: Screenshot capture, OCR, window enumeration, browser tab discovery
- **Concurrency**: Swift async/await with TaskGroups for parallel capture

`WindowManager.refresh()` runs on the main thread once per second while the sidebar is
visible, so it must never make a blocking call. Browser tab discovery uses AppleScript,
and an Apple Event send blocks the calling thread until the target app replies (up to the
AE default timeout of ~2 minutes). It therefore runs on a dedicated serial queue and
`refresh()` only reads the resulting cache:

```swift
// refresh() → getBrowserTabs() returns immediately from cache,
// scheduling a background refresh when the entry is older than the TTL.
if claimBrowserTabFetch(key: key, ttl: Self.browserTabCacheTTL) {
    Self.browserScriptQueue.async { [weak self] in
        let result = Self.runBrowserTabScript(scriptSource)
        ...
    }
}
return getCachedBrowserTabs(key: key)
```

The queue is serial because `NSAppleScript` is not thread safe, and an in-flight set
prevents duplicate scripts from queueing up for the same browser.

```swift
// Parallel thumbnail loading
await withTaskGroup(of: (UInt32, NSImage?).self) { group in
    for window in windows {
        group.addTask {
            let thumb = await captureThumbnail(window: window, ...)
            return (window.windowID, thumb)
        }
    }
    for await (windowID, thumb) in group {
        if let thumb = thumb {
            thumbnails[windowID] = thumb
        }
    }
}
```

## Dependencies

- **KeyboardShortcuts** - Global hotkey handling
- **Sparkle** - Auto-updates

## Required Permissions

1. **Accessibility** - Window management, tab switching
2. **Screen Recording** - Screenshot capture, OCR

## Private APIs Used

| API | Purpose |
|-----|---------|
| `_AXUIElementGetWindow` | Get windowID from AXUIElement |
| `_AXUIElementCreateWithRemoteToken` | Find AX elements for other-space windows |
| `_SLPSSetFrontProcessWithOptions` | Space switching |
| `SLPSPostEventRecordTo` | Make window key |
| `CGSHWCaptureWindowList` | Capture other-space windows |
| `CGSSetGlobalHotKeyOperatingMode` | Disable Cmd+Tab while active |
| `SLSMainConnectionID` | SkyLight connection |
