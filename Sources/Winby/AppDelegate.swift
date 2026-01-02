import Cocoa
import SwiftUI
import KeyboardShortcuts
import Sparkle
import Carbon.HIToolbox

// Global reference for CGEventTap callback (internal for extensions)
var globalAppDelegate: AppDelegate?

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var previewWindow: NSWindow?
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    // Updater is only available in proper app bundles with SUFeedURL configured
    lazy var updaterController: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            debugLog("Sparkle disabled: no SUFeedURL in bundle (local dev build?)")
            return nil
        }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    // Event tap for Cmd+Tab interception - internal for extensions
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?

    // Carbon hotkey for Cmd+Tab (bypasses system handler) - internal for extensions
    var carbonHotKeyRef: EventHotKeyRef?
    var carbonEventHandler: EventHandlerRef?

    // Track if we're in tab-cycling mode (second+ Tab press while Cmd held)
    var isTabCycling = false
    // Temporarily set when raising windows to prevent auto-hide
    var isRaisingWindow = false

    // Local event monitor for catching hotkey when app has focus - internal for extensions
    var localEventMonitor: Any?

    // Global click monitor for dismissing on click outside
    private var globalClickMonitor: Any?

    // Track the previously focused app to restore on dismiss without selection
    private var previouslyFocusedApp: NSRunningApplication?
    // Track if a window was selected (to know whether to restore focus)
    var didSelectWindow = false

    // Onboarding window for first-run experience
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create floating panel window (always needed)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: [.titled, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window = panel

        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        // Prevent focus loss to other windows when sidebar is visible
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self = self, self.window.isVisible else { return }
            // Immediately reclaim focus if sidebar loses it while visible
            DispatchQueue.main.async {
                guard self.window.isVisible && !self.window.isKeyWindow else { return }

                let keyWindow = NSApp.keyWindow
                debugLog("Sidebar resigned key, new key window: \(keyWindow?.title ?? "none")")

                // Don't reclaim if settings has focus (preview is .nonactivatingPanel so won't become key)
                if keyWindow == self.settingsWindow {
                    return
                }

                // Some other window stole focus - reclaim it
                debugLog("Reclaiming focus for sidebar")
                self.window.makeKey()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Add visual effect background for translucency
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow

        let hostingView = NSHostingView(rootView: SidebarView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        panel.contentView = visualEffect

        // Position on left side of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: screenFrame.origin.x,
                    y: screenFrame.origin.y,
                    width: 280,
                    height: screenFrame.height
                ),
                display: true
            )
        }

        // Keep window on top
        panel.level = .popUpMenu  // Higher than .floating to stay above activated apps
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Start hidden - user activates with hotkey
        panel.orderOut(nil)

        // Create preview panel (centered on screen, shows large window preview)
        setupPreviewWindow()

        // Auto-hide when window loses focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        // Also add a status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Winby")
        statusMenu = createMenu()
        statusMenu?.delegate = self
        statusItem?.menu = statusMenu

        // Set up main menu with Edit menu for standard shortcuts
        setupMainMenu()

        // Check if this is first run - show onboarding if not completed
        if !AppConfig.shared.hasCompletedOnboarding {
            showOnboardingWindow()
        } else {
            // Already onboarded - set up hotkeys and verify permissions
            setupGlobalHotkey()
            requestAccessibilityPermissions()

            // Request screen capture permission if not granted
            if !CGPreflightScreenCaptureAccess() {
                debugLog("Requesting screen capture permission...")
                let granted = CGRequestScreenCaptureAccess()
                debugLog("Screen capture permission granted: \(granted)")
            }

            // Start the updater (we delay it during onboarding)
            updaterController?.startUpdater()
        }
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)

        // Edit menu (for cmd+a/x/c/v)
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func setupPreviewWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Calculate preview size (leave room for sidebar and margins)
        let sidebarWidth: CGFloat = 280
        let margin: CGFloat = 40
        let availableWidth = screenFrame.width - sidebarWidth - margin * 2
        let availableHeight = screenFrame.height - margin * 2
        let previewWidth = min(availableWidth, availableHeight * 16 / 9)  // 16:9 aspect ratio max
        let previewHeight = previewWidth * 9 / 16

        let previewPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewWindow = previewPanel

        previewPanel.isMovableByWindowBackground = false  // We handle dragging in SwiftUI
        previewPanel.becomesKeyOnlyIfNeeded = true
        previewPanel.hidesOnDeactivate = false
        previewPanel.isOpaque = false
        previewPanel.backgroundColor = .clear
        previewPanel.hasShadow = false  // No border/shadow around the preview
        previewPanel.level = .popUpMenu
        previewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        previewPanel.minSize = NSSize(width: 200, height: 150)

        // Persist window position/size across restarts
        previewPanel.setFrameAutosaveName("WinbyPreviewWindow")

        // No background - just the screenshot with shadow
        let hostingView = NSHostingView(rootView: PreviewPanelView())
        previewPanel.contentView = hostingView

        // Only set default position if no saved frame exists
        if !previewPanel.setFrameUsingName("WinbyPreviewWindow") {
            // Center the preview panel (accounting for sidebar on left)
            let centerX = screenFrame.origin.x + sidebarWidth + (screenFrame.width - sidebarWidth - previewWidth) / 2
            let centerY = screenFrame.origin.y + (screenFrame.height - previewHeight) / 2
            previewPanel.setFrame(
                NSRect(x: centerX, y: centerY, width: previewWidth, height: previewHeight),
                display: true
            )
        }

        previewPanel.orderOut(nil)
    }

    @MainActor
    func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Winby (\(AppConfig.shared.hotkeyDescription))", action: #selector(toggleSidebar), keyEquivalent: "")
        menu.addItem(.separator())
        if let controller = updaterController {
            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = controller
            menu.addItem(updateItem)
        }
        menu.addItem(withTitle: "Preferences...", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Winby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Update the hotkey in the first menu item when menu opens
        if let firstItem = menu.item(at: 0) {
            firstItem.title = "Show Winby (\(AppConfig.shared.hotkeyDescription))"
        }
    }

    var settingsWindow: NSWindow?

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.title = "Winby Preferences"
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.center()

            // Add visual effect background
            let visualEffect = NSVisualEffectView()
            visualEffect.material = .windowBackground
            visualEffect.state = .active
            visualEffect.blendingMode = .behindWindow

            let hostingView = NSHostingView(rootView: OnboardingView())
            hostingView.translatesAutoresizingMaskIntoConstraints = false

            visualEffect.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
            ])

            window.contentView = visualEffect
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideOnboardingWindow() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil

        // After onboarding, set up the hotkey and other runtime things
        setupGlobalHotkey()

        // Now start the updater (we delayed it to avoid errors during onboarding)
        updaterController?.startUpdater()
    }

    @objc func debugDumpContent() {
        WindowManager.shared.debugContentFetch()
        debugLog("Content dump written to /tmp/wm_debug.log")
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        // Don't auto-hide while sidebar is visible - we raise other windows during preview
        // Only hide on explicit dismiss (Escape, Return, clicking a window, etc.)
    }

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

        // Select the current window (first in list) when sidebar opens
        let manager = WindowManager.shared
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

        // Clear cycling state
        isTabCycling = false
        WindowManager.shared.isCycling = false
        WindowManager.shared.sidebarVisible = false

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
