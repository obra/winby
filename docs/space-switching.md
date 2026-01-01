# Space Switching on macOS

Technical documentation for programmatically switching to windows on other Spaces/Desktops.

## The Challenge

macOS doesn't provide public APIs for switching Spaces. When a window is on a different Space:
- Normal `NSApplication.activate()` won't switch to it
- `AXUIElementPerformAction(kAXRaiseAction)` won't work because AX can't find the window
- The window isn't in `AXUIElementCopyAttributeValue(kAXWindowsAttribute)`

## Solution: SkyLight Private Framework

Winby uses Apple's private SkyLight framework (part of CoreGraphics) for space switching.

### Required Declarations

```swift
// Connection ID
@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

// Set front process with options - THIS is the key function
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ windowID: UInt32,
    _ mode: UInt32
) -> CGError

// Mode flags
enum SLPSMode: UInt32 {
    case normal = 0x0
    case userGenerated = 0x200  // Triggers space switch
}

// Make window key
@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError

// Disable/enable system hotkeys while switcher is active
@_silgen_name("CGSSetGlobalHotKeyOperatingMode")
func CGSSetGlobalHotKeyOperatingMode(_ connection: Int32, _ mode: Int32) -> CGError
```

### The Focus Sequence

This is the proven sequence from alt-tab-macos:

```swift
func focusWindow(windowID: UInt32, pid: pid_t) {
    // 1. Get process serial number
    var psn = ProcessSerialNumber()
    GetProcessForPID(pid, &psn)

    // 2. Set front process with userGenerated mode
    // This brings the process to front AND signals user intent for space switch
    _SLPSSetFrontProcessWithOptions(&psn, windowID, SLPSMode.userGenerated.rawValue)

    // 3. Make the window key (sends binary protocol to WindowServer)
    makeKeyWindow(&psn, windowID)

    // 4. Raise via AX API - THIS triggers the actual space switch
    if let axElement = findAXUIElement(forWindowID: windowID, pid: pid) {
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }
}

func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: UInt32) {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x08] = 0x01
    bytes[0x3a] = 0x10

    // Encode window ID at specific offsets
    bytes[0x3c] = UInt8(windowID & 0xFF)
    bytes[0x3d] = UInt8((windowID >> 8) & 0xFF)
    bytes[0x3e] = UInt8((windowID >> 16) & 0xFF)
    bytes[0x3f] = UInt8((windowID >> 24) & 0xFF)

    // PSN encoded at offset 0x20
    let psnLow = UInt64(psn.lowLongOfPSN)
    let psnHigh = UInt64(psn.highLongOfPSN)
    let psnValue = psnLow | (psnHigh << 32)
    for i in 0..<8 {
        bytes[0x20 + i] = UInt8((psnValue >> (i * 8)) & 0xFF)
    }

    SLPSPostEventRecordTo(&psn, &bytes)
}
```

## Finding AXUIElement for Other-Space Windows

Normal AX APIs can't find windows on other spaces. Use brute-force token probing:

```swift
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ pid: pid_t, _ token: UnsafeRawPointer, _ len: Int32) -> AXUIElement?

func findAXUIElement(forWindowID windowID: UInt32, pid: pid_t) -> AXUIElement? {
    // Probe token structures until we find the right one
    for tokenValue: UInt32 in 0..<65536 {
        var token = [UInt8](repeating: 0, count: 20)

        // Encode potential token structure
        token[0] = 0x00
        token[1] = 0x62
        token[2] = 0x00
        token[3] = 0x00

        // Window ID at offset 4
        token[4] = UInt8(windowID & 0xFF)
        token[5] = UInt8((windowID >> 8) & 0xFF)
        token[6] = UInt8((windowID >> 16) & 0xFF)
        token[7] = UInt8((windowID >> 24) & 0xFF)

        // Token value at offset 8
        token[8] = UInt8(tokenValue & 0xFF)
        token[9] = UInt8((tokenValue >> 8) & 0xFF)
        token[10] = 0x00
        token[11] = 0x00

        // More header bytes
        token[12] = 0x00
        token[13] = 0x00
        token[14] = 0x01
        token[15] = 0x00

        if let element = token.withUnsafeBytes({ ptr in
            _AXUIElementCreateWithRemoteToken(pid, ptr.baseAddress!, 20)
        }) {
            // Verify this element has the right window ID
            var foundID: UInt32 = 0
            if _AXUIElementGetWindow(element, &foundID) == .success,
               foundID == windowID {
                return element
            }
        }
    }
    return nil
}
```

**Note**: This brute-force approach is slow (can take 100ms+). Only use it for windows not on the current space.

## Disabling System Hotkeys

While the window switcher is active, disable system hotkeys to prevent Cmd+Tab from triggering the system switcher:

```swift
// Disable when showing switcher
CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 1)  // 1 = disable

// Re-enable when hiding
CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 0)  // 0 = enable
```

## Background Tabs on Other Spaces

Background tabs (e.g., non-frontmost tabs in Terminal) require special handling:

1. **Switch the tab first** using AX radio button click
2. **Then** perform the space switch sequence
3. For tabs on current space, skip the space switch entirely (the tab click handles focus)

```swift
if isBackgroundTab {
    // Switch tab
    selectTabViaAX(pid: pid, tabTitle: tabTitle)

    // If on current space, we're done - tab click focused the window
    if window.isOnCurrentSpace {
        return
    }
    // Otherwise, continue with space switch sequence...
}
```

## Known Issues

1. **Brute-force token probing is slow** - Cache results when possible
2. **Private APIs may change** - These work on macOS 14, may break in future versions
3. **Some apps resist focus** - Electron apps and some others may need extra handling
4. **Full-screen spaces** - May require additional handling

## References

- [alt-tab-macos source](https://github.com/lwouis/alt-tab-macos) - Primary reference implementation
- [SkyLight.framework.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/api-wrappers/private-apis/SkyLight.framework.swift)
