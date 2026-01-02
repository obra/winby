import Cocoa

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

    // Cached app icon (looked up once at creation, not on every access)
    let appIcon: NSImage?

    // Unique ID for SwiftUI (handles tabs sharing same windowID)
    var id: String {
        "\(windowID)-\(pid)-\(title)-\(duplicateIndex)"
    }

    // Hashable conformance - use id (excludes appIcon since NSImage isn't Hashable)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
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
}
