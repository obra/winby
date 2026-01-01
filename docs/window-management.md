# Window Management on macOS

Technical documentation for enumerating and managing windows programmatically on macOS.

## Overview

Winby uses multiple APIs to enumerate windows:
1. **CGWindowList** - Fast, returns all windows including other spaces
2. **Accessibility API** - Detailed info, tabs, but only current space by default
3. **SkyLight (Private)** - Window activation, space switching

## CGWindowList API

Fast enumeration of all windows across all spaces.

```swift
import CoreGraphics

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    return
}

for windowInfo in windowList {
    let windowID = windowInfo[kCGWindowNumber as String] as? UInt32
    let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t
    let title = windowInfo[kCGWindowName as String] as? String
    let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat]
    let layer = windowInfo[kCGWindowLayer as String] as? Int  // 0 = normal window
    let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool
}
```

### Key Properties

- `kCGWindowNumber` - Unique window ID (UInt32)
- `kCGWindowOwnerPID` - Process ID of owning app
- `kCGWindowName` - Window title (may be nil)
- `kCGWindowBounds` - Frame as dictionary with x, y, width, height
- `kCGWindowLayer` - Layer level (0 = normal, others are system UI)
- `kCGWindowIsOnscreen` - Whether window is currently visible

### Limitations

- **No tab information** - Background tabs in Safari, Terminal, etc. are not listed
- **No space information directly** - Must cross-reference with other APIs
- **Window IDs change** - IDs are not persistent across app restarts

## Accessibility API (AXUIElement)

Detailed window information including tabs, but requires Accessibility permission.

```swift
import ApplicationServices

// Get app element
let appElement = AXUIElementCreateApplication(pid)

// Get windows
var windowsRef: CFTypeRef?
AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
guard let windows = windowsRef as? [AXUIElement] else { return }

for window in windows {
    // Get title
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
    let title = titleRef as? String

    // Get position
    var positionRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)

    // Get size
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

    // Get window ID (private API)
    var windowID: UInt32 = 0
    _AXUIElementGetWindow(window, &windowID)
}
```

### Getting Window ID from AXUIElement

```swift
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError
```

### Finding Tab Groups

Native macOS apps expose tabs as `AXRadioButton` elements inside an `AXTabGroup`:

```swift
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
```

### Enumerating Tabs

```swift
// Standard tabs (some apps)
var tabsRef: CFTypeRef?
AXUIElementCopyAttributeValue(tabGroup, kAXTabsAttribute as CFString, &tabsRef)

// Radio button tabs (Terminal, Ghostty)
var childrenRef: CFTypeRef?
AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef)
let children = childrenRef as? [AXUIElement] ?? []

for child in children {
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
    if (roleRef as? String) == "AXRadioButton" {
        // This is a tab
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)

        // Check if selected
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)
        let isSelected = (valueRef as? Int) == 1
    }
}
```

## Determining Current Space

CGWindowList doesn't directly tell you which space a window is on. Use this approach:

```swift
// Get windows on current space only
let currentSpaceWindows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []

let currentSpaceWindowIDs = Set(currentSpaceWindows.compactMap {
    $0[kCGWindowNumber as String] as? UInt32
})

// Later, check if a window is on current space
let isOnCurrentSpace = currentSpaceWindowIDs.contains(windowID)
```

## Deduplication Challenges

### Background Tabs Have Different IDs

When enumerating via AX, background tabs get synthetic window IDs that differ from CGWindowList:
- AX might report tab as window ID `0x80000000 | hash`
- CGWindowList reports the real window ID

### Solution: Title-Based Deduplication

```swift
func normalizeTitle(_ title: String) -> String {
    var t = title
    // Strip terminal dimensions like " — 124×36" at the end
    if let range = t.range(of: #" — \d+×\d+$"#, options: .regularExpression) {
        t.removeSubrange(range)
    }
    // Handle ellipsis truncation
    t = t.replacingOccurrences(of: "…", with: "")
    return t
}

// Skip CG windows that match an AX-enumerated title
let normalizedCGTitle = normalizeTitle(cgTitle)
let isDuplicate = axWindowsByApp[appName]?.contains { window in
    normalizeTitle(window.title).hasPrefix(normalizedCGTitle) ||
    normalizedCGTitle.hasPrefix(normalizeTitle(window.title))
} ?? false
```

## Window Actions

### Raise Window

```swift
AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
```

### Minimize/Unminimize

```swift
// Minimize
AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)

// Unminimize
AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
```

### Close Window

```swift
AXUIElementPerformAction(windowElement, kAXCloseAction as CFString)
```

## Required Permissions

Window management requires **Accessibility** permission:
System Settings > Privacy & Security > Accessibility

Check and request:
```swift
let trusted = AXIsProcessTrustedWithOptions([
    kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
] as CFDictionary)
```

## Related Projects

- [AXSwift](https://github.com/tmandry/AXSwift) - Swift wrapper for AX APIs
- [Swindler](https://github.com/tmandry/Swindler) - Window management library
- [alt-tab-macos](https://github.com/lwouis/alt-tab-macos) - Reference implementation
