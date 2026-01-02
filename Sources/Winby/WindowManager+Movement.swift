import Cocoa

// MARK: - Window Movement

extension WindowManager {
    func moveWindow(_ windowID: UInt32, to point: CGPoint) {
        var p = point
        _ = SLSMoveWindow(cid, windowID, &p)
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
}
