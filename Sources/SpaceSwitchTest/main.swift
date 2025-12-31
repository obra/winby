#!/usr/bin/env swift
// SpaceSwitchTest - Test different space-switching techniques
// Usage: SpaceSwitchTest [technique] [windowID]
// Techniques: sls, applescript, anchor

import Cocoa
import ApplicationServices

// Store command for use after NSApplication starts
var pendingCommand: String?
var pendingArg: String?

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permission first
        let trusted = AXIsProcessTrusted()
        print("Accessibility permission: \(trusted ? "GRANTED" : "NOT GRANTED")")

        if !trusted {
            print("Requesting accessibility permission...")
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            print("Please grant accessibility permission in System Settings and re-run.")
        }

        // Run the actual test after app is fully launched
        DispatchQueue.main.async {
            runTest()
            // Wait longer to see if anything happens
            print("  Waiting 2 seconds before exit...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("  Exiting.")
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Private API Declarations

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ displayUuid: CFString) -> CGSSpaceID

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ wids: CFArray) -> CFArray

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: CFArray, _ options: Int, _ setTags: UnsafeMutablePointer<Int>, _ clearTags: UnsafeMutablePointer<Int>) -> CFArray

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

// Create AXUIElement from a remote token (for brute-forcing elements)
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

// MARK: - Helper Functions

/// Brute-force find AXUIElement for a window ID (alt-tab's approach for other-space windows)
func findAXUIElement(forWindowID targetWindowID: UInt32, pid: pid_t) -> AXUIElement? {
    print("  Brute-forcing AXUIElement for window \(targetWindowID) (pid \(pid))...")

    // Token format from alt-tab: pid (4 bytes) + 0 (4 bytes) + 0x636f636f (4 bytes) + elementID (8 bytes)
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
            print("  Found AXUIElement at elementID \(elementID) for window \(targetWindowID)!")
            return element
        }
    }

    print("  Could not find AXUIElement for window \(targetWindowID) (tried 1000 element IDs)")
    return nil
}

/// Perform AXRaise on an element
func axRaise(_ element: AXUIElement) -> Bool {
    let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    return result == .success
}

func getMainDisplayUUID() -> CFString? {
    let cid = CGSMainConnectionID()
    guard let spacesInfo = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
          let firstDisplay = spacesInfo.first,
          let displayID = firstDisplay["Display Identifier"] as? String else {
        return nil
    }
    return displayID as CFString
}

func getCurrentSpaceID() -> CGSSpaceID? {
    let cid = CGSMainConnectionID()
    guard let displayUUID = getMainDisplayUUID() else { return nil }
    return CGSManagedDisplayGetCurrentSpace(cid, displayUUID)
}

func getSpaceForWindow(_ windowID: UInt32) -> CGSSpaceID? {
    let cid = CGSMainConnectionID()
    let windowArray = [windowID as CFNumber] as CFArray
    let spaces = CGSCopySpacesForWindows(cid, 0x7, windowArray)
    guard let spaceIDs = spaces as? [CGSSpaceID], let first = spaceIDs.first else {
        return nil
    }
    return first
}

func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
    // Exact alt-tab implementation
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10

    // Copy window ID at offset 0x3c (using memcpy like alt-tab)
    var wid = windowID
    memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)

    // Fill 0x20-0x2f with 0xff (using memset like alt-tab)
    memset(&bytes[0x20], 0xff, 0x10)

    // Set 0x08 right before the call (like alt-tab)
    bytes[0x08] = 0x01
    let r1 = SLPSPostEventRecordTo(&psn, &bytes)
    print("    SLPSPostEventRecordTo (0x01) result: \(r1.rawValue)")

    bytes[0x08] = 0x02
    let r2 = SLPSPostEventRecordTo(&psn, &bytes)
    print("    SLPSPostEventRecordTo (0x02) result: \(r2.rawValue)")
}

struct WindowInfo {
    let windowID: UInt32
    let pid: pid_t
    let appName: String
    let title: String
    let spaceID: CGSSpaceID?
    let isOnCurrentSpace: Bool
}

func getAllSpaceIDs() -> [CGSSpaceID] {
    let cid = CGSMainConnectionID()
    guard let spacesInfo = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
        return []
    }

    var allSpaces: [CGSSpaceID] = []
    for display in spacesInfo {
        if let spaces = display["Spaces"] as? [[String: Any]] {
            for space in spaces {
                if let spaceID = space["id64"] as? CGSSpaceID {
                    allSpaces.append(spaceID)
                }
            }
        }
    }
    return allSpaces
}

func getWindowIDsOnAllSpaces() -> Set<UInt32> {
    let cid = CGSMainConnectionID()
    let allSpaces = getAllSpaceIDs()

    guard !allSpaces.isEmpty else { return [] }

    let spacesArray = allSpaces.map { $0 as CFNumber } as CFArray
    var setTags = 0
    var clearTags = 0

    let windowIDs = CGSCopyWindowsWithOptionsAndTags(cid, 0, spacesArray, 2, &setTags, &clearTags)

    guard let ids = windowIDs as? [CGWindowID] else { return [] }
    return Set(ids)
}

func listWindows() -> [WindowInfo] {
    let currentSpace = getCurrentSpaceID()
    var results: [WindowInfo] = []

    // Get window IDs from ALL spaces using private API
    let allSpaceWindowIDs = getWindowIDsOnAllSpaces()
    print("  (Found \(allSpaceWindowIDs.count) windows across all spaces via CGS)")

    // Get window info using standard API
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return results
    }

    // Build a map of windowID -> info
    var windowInfoMap: [UInt32: [String: Any]] = [:]
    for info in windowList {
        if let windowID = info[kCGWindowNumber as String] as? UInt32 {
            windowInfoMap[windowID] = info
        }
    }

    // Process all windows from all spaces
    for windowID in allSpaceWindowIDs {
        guard let info = windowInfoMap[windowID],
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              layer == 0 else {
            continue
        }

        let appName = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
        let title = info[kCGWindowName as String] as? String ?? ""

        // Skip windows without titles or system apps
        if title.isEmpty { continue }
        if ["Window Server", "Dock", "Control Center"].contains(appName) { continue }

        let spaceID = getSpaceForWindow(windowID)
        let isOnCurrentSpace = spaceID == currentSpace

        results.append(WindowInfo(
            windowID: windowID,
            pid: pid,
            appName: appName,
            title: title,
            spaceID: spaceID,
            isOnCurrentSpace: isOnCurrentSpace
        ))
    }

    return results
}

// MARK: - Space Switch Techniques

// Global to hold window reference
var testWindow: NSWindow?

func technique_SLS(windowID: UInt32, pid: pid_t) {
    print("  Technique: SLS (_SLPSSetFrontProcessWithOptions + makeKeyWindow + AXRaise)")

    // First, try to find the AXUIElement for this window using brute-force (like alt-tab)
    let axElement = findAXUIElement(forWindowID: windowID, pid: pid)
    if axElement == nil {
        print("  WARNING: Could not find AXUIElement - will try SLS without AXRaise")
    }

    // Create and show a window first (like alt-tab has its picker visible)
    print("  Creating a visible window first (like alt-tab's picker)...")
    testWindow = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    testWindow?.title = "SpaceSwitchTest"
    testWindow?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)

    Thread.sleep(forTimeInterval: 0.2)
    print("  Window shown, we are now frontmost")

    print("  Getting PSN for pid \(pid)...")

    var psn = ProcessSerialNumber()
    let status = GetProcessForPID(pid, &psn)
    print("  GetProcessForPID status: \(status) (0 = success)")
    print("  PSN: highLong=\(psn.highLongOfPSN), lowLong=\(psn.lowLongOfPSN)")

    if psn.highLongOfPSN == 0 && psn.lowLongOfPSN == 0 {
        print("  ERROR: PSN is zero - GetProcessForPID failed!")
        return
    }

    // Try from background queue like alt-tab does
    print("\n  --- Full alt-tab approach: SLS + makeKeyWindow + AXRaise from background queue ---")

    let queue = DispatchQueue(label: "accessibilityCommandsQueue", qos: .userInteractive)
    let semaphore = DispatchSemaphore(value: 0)

    queue.async {
        var bgPsn = psn  // Copy for background

        // Step 1: _SLPSSetFrontProcessWithOptions
        print("  [BG] Step 1: _SLPSSetFrontProcessWithOptions with userGenerated mode...")
        let result = _SLPSSetFrontProcessWithOptions(&bgPsn, windowID, SLPSMode.userGenerated.rawValue)
        print("  [BG] Result: \(result.rawValue)")

        // Step 2: makeKeyWindow
        print("  [BG] Step 2: makeKeyWindow...")
        makeKeyWindow(&bgPsn, windowID)
        print("  [BG] makeKeyWindow done")

        // Step 3: AXRaise (the key step alt-tab does that we were missing!)
        if let element = axElement {
            print("  [BG] Step 3: AXUIElementPerformAction(kAXRaiseAction)...")
            let raiseResult = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            print("  [BG] AXRaise result: \(raiseResult.rawValue) (0 = success)")
        } else {
            print("  [BG] Step 3: SKIPPED (no AXUIElement)")
        }

        semaphore.signal()
    }

    // Wait for background work
    semaphore.wait()

    Thread.sleep(forTimeInterval: 0.5)
    print("  Current space after: \(getCurrentSpaceID() ?? 0)")

    // Hide our window
    testWindow?.orderOut(nil)

    print("\n  Done testing.")
}

func technique_AppleScript(spaceIndex: Int) {
    print("  Technique: AppleScript keyboard simulation (Ctrl+\(spaceIndex))")

    // Key codes for numbers 1-9
    let keycodes: [Int: Int] = [
        1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
        6: 22, 7: 26, 8: 28, 9: 25, 0: 29
    ]

    guard let keycode = keycodes[spaceIndex] else {
        print("  Error: Invalid space index \(spaceIndex)")
        return
    }

    let script = """
    tell application "System Events"
        key code \(keycode) using {control down}
    end tell
    """

    print("  Executing: key code \(keycode) using {control down}")

    var error: NSDictionary?
    if let appleScript = NSAppleScript(source: script) {
        appleScript.executeAndReturnError(&error)
        if let error = error {
            print("  Error: \(error)")
        } else {
            print("  Done. Check if space switched.")
        }
    }
}

func technique_Anchor() {
    print("  Technique: Anchor Window (creates window, switches to it)")
    print("  This technique requires pre-created anchor windows on each space.")
    print("  Not implemented in this test - see SpaceSwitcher library for full implementation.")
    print("  Basic idea: create invisible window on target space, then makeKeyAndOrderFront() on it.")
}

func technique_ActivateApp(pid: pid_t) {
    print("  Technique: NSRunningApplication.activate()")

    guard let app = NSRunningApplication(processIdentifier: pid) else {
        print("  Error: Could not find app with pid \(pid)")
        return
    }

    print("  Activating \(app.localizedName ?? "app") with activateIgnoringOtherApps...")
    let result = app.activate(options: [.activateIgnoringOtherApps])
    print("  Result: \(result)")
    print("  Done. Check if space switched.")
}

// MARK: - Main

func printUsage() {
    print("""
    SpaceSwitchTest - Test space-switching techniques

    Usage: SpaceSwitchTest [command]

    Commands:
      list              List all windows with their space info
      sls <windowID>    Test SLS technique on window
      applescript <N>   Test AppleScript Ctrl+N (space index 1-9)
      activate <windowID>  Test NSRunningApplication.activate()
      anchor            Show info about anchor window technique

    Example:
      SpaceSwitchTest list
      SpaceSwitchTest sls 1234
      SpaceSwitchTest applescript 2
    """)
}

func runTest() {
    let args = CommandLine.arguments

    let command = pendingCommand ?? (args.count >= 2 ? args[1] : nil)
    let arg = pendingArg ?? (args.count >= 3 ? args[2] : nil)

    guard let command = command else {
        printUsage()

        print("\n--- Current Windows ---")
        let currentSpace = getCurrentSpaceID()
        print("Current space: \(currentSpace ?? 0)\n")

        let windows = listWindows()
        let otherSpaceWindows = windows.filter { !$0.isOnCurrentSpace }

        if otherSpaceWindows.isEmpty {
            print("No windows found on other spaces.")
            print("Create windows on different spaces to test space switching.")
        } else {
            print("Windows on OTHER spaces (good for testing):")
            for w in otherSpaceWindows.prefix(10) {
                print("  [\(w.windowID)] \(w.appName): \"\(w.title)\" (space \(w.spaceID ?? 0))")
            }
            print("\nTry: SpaceSwitchTest sls \(otherSpaceWindows.first!.windowID)")
        }
        return
    }

    switch command {
    case "list":
        let currentSpace = getCurrentSpaceID()
        print("Current space: \(currentSpace ?? 0)\n")

        let windows = listWindows()
        print("Windows on CURRENT space:")
        for w in windows.filter({ $0.isOnCurrentSpace }).prefix(10) {
            print("  [\(w.windowID)] \(w.appName): \"\(w.title)\"")
        }
        print("\nWindows on OTHER spaces:")
        for w in windows.filter({ !$0.isOnCurrentSpace }).prefix(10) {
            print("  [\(w.windowID)] \(w.appName): \"\(w.title)\" (space \(w.spaceID ?? 0))")
        }

    case "sls":
        guard let arg = arg, let windowID = UInt32(arg) else {
            print("Usage: SpaceSwitchTest sls <windowID>")
            return
        }

        let windows = listWindows()
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            print("Window \(windowID) not found")
            return
        }

        print("Target: [\(windowID)] \(window.appName): \"\(window.title)\"")
        print("  Space: \(window.spaceID ?? 0), Current space: \(getCurrentSpaceID() ?? 0)")
        print("  On current space: \(window.isOnCurrentSpace)")
        print("")

        technique_SLS(windowID: windowID, pid: window.pid)

    case "applescript":
        guard let arg = arg, let spaceIndex = Int(arg), spaceIndex >= 1, spaceIndex <= 9 else {
            print("Usage: SpaceSwitchTest applescript <1-9>")
            return
        }

        technique_AppleScript(spaceIndex: spaceIndex)

    case "activate":
        guard let arg = arg, let windowID = UInt32(arg) else {
            print("Usage: SpaceSwitchTest activate <windowID>")
            return
        }

        let windows = listWindows()
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            print("Window \(windowID) not found")
            return
        }

        print("Target: [\(windowID)] \(window.appName): \"\(window.title)\"")
        technique_ActivateApp(pid: window.pid)

    case "anchor":
        technique_Anchor()

    default:
        printUsage()
    }
}

// Parse args before starting NSApplication
let args = CommandLine.arguments
if args.count >= 2 {
    pendingCommand = args[1]
}
if args.count >= 3 {
    pendingArg = args[2]
}

// Run as a proper NSApplication to get full GUI context
print("Starting NSApplication context...")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Menu bar app, no dock icon
app.run()
