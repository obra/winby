import Cocoa
import SwiftUI

// MARK: - Sidebar Management

extension AppDelegate {
    @objc func toggleSidebar() {
        if window.isVisible {
            hideSidebar()
        } else {
            showSidebar()
        }
    }

    /// Save the currently focused app to restore later if Winby is dismissed without selection
    func savePreviousFocus() {
        // Get frontmost app that isn't Winby
        let frontmost = NSWorkspace.shared.frontmostApplication
        let winbyPID = ProcessInfo.processInfo.processIdentifier

        if let app = frontmost, app.processIdentifier != winbyPID {
            previouslyFocusedApp = app
            debugLog("Saved previous app: \(app.localizedName ?? "unknown") (pid: \(app.processIdentifier))")
        } else {
            debugLog("Could not find non-Winby frontmost app (frontmost is \(frontmost?.localizedName ?? "none"))")
        }
        didSelectWindow = false
    }

    func showSidebar() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Disable system hotkeys (like Cmd+Tab) while our switcher is active
        _ = CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 1)  // 1 = disable

        // Position at left edge of screen
        window.setFrame(
            NSRect(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y,
                width: 280,
                height: screenFrame.height
            ),
            display: false
        )

        // Start refreshing and select the current window when sidebar opens
        let manager = WindowManager.shared
        manager.startRefreshing()
        manager.sidebarVisible = true
        if let firstWindow = manager.windows.first {
            manager.selectedWindowID = firstWindow.windowID
        }

        // Fade in
        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        // Show preview panel with fade in
        if let preview = previewWindow {
            preview.alphaValue = 0
            preview.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                preview.animator().alphaValue = 1
            }
        }

        // Add global click monitor to dismiss when clicking outside both windows
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return }

            let screenLocation = NSEvent.mouseLocation

            // Check if click is inside sidebar window
            if self.window.frame.contains(screenLocation) {
                return
            }

            // Check if click is inside preview window
            if let preview = self.previewWindow, preview.frame.contains(screenLocation) {
                return
            }

            // Click was outside both windows - dismiss
            self.hideSidebar()
        }
    }

    func hideSidebar() {
        // Remove global click monitor
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

        // Clear cycling state and stop refreshing
        isTabCycling = false
        WindowManager.shared.isCycling = false
        WindowManager.shared.sidebarVisible = false
        WindowManager.shared.stopRefreshing()

        // Re-enable system hotkeys
        _ = CGSSetGlobalHotKeyOperatingMode(SLSMainConnectionID(), 0)  // 0 = enable

        // Restore focus to previous app if no window was selected
        if !didSelectWindow, let previousApp = previouslyFocusedApp {
            debugLog("Restoring focus to: \(previousApp.localizedName ?? "unknown") (pid: \(previousApp.processIdentifier))")
            previousApp.activate()

            // Also try to bring the frontmost window to front using AX
            let appElement = AXUIElementCreateApplication(previousApp.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement],
               let frontWindow = windows.first {
                AXUIElementPerformAction(frontWindow, kAXRaiseAction as CFString)
                debugLog("Raised previous app's front window via AX")
            }
        } else if !didSelectWindow {
            debugLog("No previous app to restore focus to")
        } else {
            debugLog("Window was selected, not restoring previous focus")
        }
        previouslyFocusedApp = nil

        // Reset sidebar state
        WindowManager.shared.sidebarResetTrigger.toggle()

        // Hide preview panel with fade out
        if let preview = previewWindow {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                preview.animator().alphaValue = 0
            }, completionHandler: {
                preview.orderOut(nil)
            })
        }

        // Fade out sidebar
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.window.animator().alphaValue = 0
        }, completionHandler: {
            self.window.orderOut(nil)

            // Cache background tab screenshots if enabled (requires both settings)
            // Run after a short delay to let the UI settle
            if AppConfig.shared.cacheBackgroundTabs && AppConfig.shared.showBackgroundTabs {
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms delay
                    await WindowManager.shared.cacheBackgroundTabScreenshots()
                }
            }
        })
    }

    @objc func refreshWindows() {
        WindowManager.shared.refresh()
    }

    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("Accessibility permissions required for full functionality")
        }
    }


    func selectNextWindow() {
        let manager = WindowManager.shared
        let windows = manager.windows

        guard !windows.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = windows.firstIndex(where: { $0.windowID == current }) {
            let nextIdx = (idx + 1) % windows.count
            manager.selectedWindowID = windows[nextIdx].windowID
        } else {
            // First invocation: select window #2 (index 1) since #1 is the current window
            // Just like standard Cmd+Tab behavior
            let idx = windows.count > 1 ? 1 : 0
            manager.selectedWindowID = windows[idx].windowID
        }
    }

    func selectPreviousWindow() {
        let manager = WindowManager.shared
        let windows = manager.windows

        guard !windows.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = windows.firstIndex(where: { $0.windowID == current }) {
            let prevIdx = idx > 0 ? idx - 1 : windows.count - 1
            manager.selectedWindowID = windows[prevIdx].windowID
        } else {
            // First invocation going backward: select last window
            manager.selectedWindowID = windows[windows.count - 1].windowID
        }
    }

    func activateSelectedAndHide() {
        let manager = WindowManager.shared
        if let windowID = manager.selectedWindowID {
            manager.bringToFront(windowID)
            didSelectWindow = true
        }
        hideSidebar()
    }
}
