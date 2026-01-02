import Cocoa
import Carbon.HIToolbox

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
