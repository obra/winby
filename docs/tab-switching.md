# Tab Switching Implementation

Technical documentation for Winby's programmatic tab switching on macOS.

## Overview

Winby can switch to background tabs within applications like Terminal, Ghostty, Safari, and Chrome. This requires different approaches depending on the application.

## Approaches by App Type

### Native macOS Apps (Terminal, Ghostty)

Native apps expose tabs as `AXRadioButton` elements inside an `AXTabGroup`. We use direct Accessibility API calls:

```swift
// Find the tab group in the window hierarchy
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

// Click the target tab
let result = AXUIElementPerformAction(targetTab, kAXPressAction as CFString)
```

**Key insight**: AppleScript via `NSAppleScript` doesn't reliably click tabs in Terminal, even though the same script works from `osascript`. Direct AX API calls are more reliable.

### Browsers (Safari, Chrome)

Browsers have native AppleScript support with dedicated tab APIs:

**Safari:**
```applescript
tell application "Safari"
    set current tab of window 1 to tab N of window 1
end tell
```

**Chrome:**
```applescript
tell application "Google Chrome"
    set active tab index of window 1 to N
end tell
```

### Other Apps (System Events Fallback)

For apps without native scripting, use System Events to click radio buttons:

```applescript
tell application "System Events"
    tell process "AppName"
        tell window 1
            click radio button N of tab group 1
        end tell
    end tell
end tell
```

## Critical Gotcha: Tab Order

**The enumeration order of tabs via Accessibility API does not match the visual order in the tab bar.**

When we enumerate `AXRadioButton` children of an `AXTabGroup`, they may come back in creation order, z-order, or some other order that doesn't match left-to-right visual position.

### Solution: Title-Based Matching

Instead of relying on tab index, match tabs by title:

```swift
private func selectTabViaAX(pid: pid_t, tabIndex: Int, tabTitle: String? = nil) -> Bool {
    // ... find tab group and enumerate radio buttons with titles ...

    // Prefer title match over index
    if let tabTitle = tabTitle {
        for (element, title) in radioButtons {
            if title == tabTitle {
                targetTab = element
                break
            }
        }
        // Try contains match if no exact match
        if targetTab == nil {
            for (element, title) in radioButtons {
                if title.contains(tabTitle) || tabTitle.contains(title) {
                    targetTab = element
                    break
                }
            }
        }
    }

    // Fall back to index only if title match failed
    if targetTab == nil && tabIndex < radioButtons.count {
        targetTab = radioButtons[tabIndex].element
    }

    // Click it
    return AXUIElementPerformAction(targetTab, kAXPressAction as CFString) == .success
}
```

## Tab Enumeration

### Standard Tabs (kAXTabsAttribute)

Some apps expose tabs via `kAXTabsAttribute`:

```swift
var tabsRef: CFTypeRef?
if AXUIElementCopyAttributeValue(element, kAXTabsAttribute as CFString, &tabsRef) == .success,
   let tabElements = tabsRef as? [AXUIElement] {
    // Process tab elements
}
```

### Radio Button Tabs (Terminal, Ghostty)

Native apps use radio buttons instead:

```swift
var childrenRef: CFTypeRef?
if AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef) == .success,
   let children = childrenRef as? [AXUIElement] {
    for child in children {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXRadioButton" {
            // This is a tab - get its title
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""

            // Check if selected via AXValue (1 = selected)
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? Int, value == 1 {
                // This tab is currently selected
            }
        }
    }
}
```

## Known Limitations

1. **Tab enumeration order unreliable** - Must use title matching, not index
2. **kAXDocumentAttribute inaccessible for background tabs** - Can't get file path for non-frontmost tabbed documents
3. **NSAppleScript unreliable** - Direct AX API more reliable than AppleScript from Swift
4. **App-specific behavior** - Each app may expose tabs differently

## Related Projects

- [AXSwift](https://github.com/tmandry/AXSwift) - Swift wrapper for Accessibility APIs
- [Swindler](https://github.com/tmandry/Swindler) - macOS window management library
- [alt-tab-macos](https://github.com/lwouis/alt-tab-macos) - Windows-style alt-tab for macOS
- [TabTab](https://tabtabapp.net/) - Commercial tab switching app

## Required Permissions

Tab switching requires **Accessibility** permission. The app must be added to:
System Settings > Privacy & Security > Accessibility
