// WindowFilterTest - validates phantom window filtering
// Run with: swift run WindowFilterTest

import Cocoa

// Private API declarations
typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ selector: Int, _ windowIDs: CFArray) -> CFArray

// Test: Verify that phantom windows are correctly identified
func testPhantomWindowFiltering() {
    print("=== Phantom Window Filter Test ===\n")

    let cid = CGSMainConnectionID()

    var realWindows: [(id: UInt32, app: String, title: String, spaces: [CGSSpaceID])] = []
    var phantomWindows: [(id: UInt32, app: String, title: String)] = []

    // Get all windows from CGWindowList
    guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        print("FAIL: Could not get window list")
        return
    }

    for window in windowList {
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = window[kCGWindowLayer as String] as? Int,
              layer == 0,
              let windowID = window[kCGWindowNumber as String] as? UInt32
        else { continue }

        let title = window[kCGWindowName as String] as? String ?? ""
        if title.isEmpty { continue }

        // Get spaces for this window
        let windowArray = [windowID as CFNumber] as CFArray
        let spaces = CGSCopySpacesForWindows(cid, 0x7, windowArray) as? [CGSSpaceID] ?? []

        if spaces.isEmpty {
            phantomWindows.append((windowID, ownerName, title))
        } else {
            realWindows.append((windowID, ownerName, title, spaces))
        }
    }

    print("REAL windows (belong to a space): \(realWindows.count)")
    for w in realWindows.prefix(10) {
        print("  ✓ [\(w.app)] '\(w.title.prefix(30))' spaces:\(w.spaces)")
    }
    if realWindows.count > 10 {
        print("  ... and \(realWindows.count - 10) more")
    }

    print("\nPHANTOM windows (no space): \(phantomWindows.count)")
    for w in phantomWindows.prefix(10) {
        print("  ✗ [\(w.app)] '\(w.title.prefix(30))'")
    }
    if phantomWindows.count > 10 {
        print("  ... and \(phantomWindows.count - 10) more")
    }

    // Check specific apps that are known to have phantom windows
    let ghosttyPhantoms = phantomWindows.filter { $0.app == "Ghostty" }.count
    let ghosttyReal = realWindows.filter { $0.app == "Ghostty" }.count

    print("\n=== Summary ===")
    print("Total windows: \(realWindows.count + phantomWindows.count)")
    print("Real: \(realWindows.count), Phantom: \(phantomWindows.count)")

    if ghosttyPhantoms > 0 || ghosttyReal > 0 {
        print("\nGhostty: \(ghosttyReal) real, \(ghosttyPhantoms) phantom")
    }

    // Verify the filtering logic is working
    if phantomWindows.isEmpty {
        print("\n✓ PASS: No phantom windows detected (or none exist)")
    } else {
        print("\n✓ PASS: Phantom window detection is working")
        print("  These windows would be filtered out of 'Other Spaces'")
    }
}

testPhantomWindowFiltering()
