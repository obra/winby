import Cocoa
import SwiftUI
import ServiceManagement
import KeyboardShortcuts

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

    /// When enabled, background tabs are shown as separate entries in the window list
    @Published var showBackgroundTabs: Bool {
        didSet { UserDefaults.standard.set(showBackgroundTabs, forKey: "showBackgroundTabs") }
    }

    /// When enabled, winby will cycle through background tabs after dismissal to cache their screenshots
    /// This causes brief visible tab switching but ensures all tabs have preview images
    @Published var cacheBackgroundTabs: Bool {
        didSet { UserDefaults.standard.set(cacheBackgroundTabs, forKey: "cacheBackgroundTabs") }
    }

    init() {
        self.debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.showBackgroundTabs = UserDefaults.standard.bool(forKey: "showBackgroundTabs")
        self.cacheBackgroundTabs = UserDefaults.standard.bool(forKey: "cacheBackgroundTabs")
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
