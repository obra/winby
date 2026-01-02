import Cocoa
import Carbon.HIToolbox
import KeyboardShortcuts

// MARK: - Hotkey Handling

extension AppDelegate {
    /// Register Cmd+Tab as a Carbon hotkey (bypasses system Dock handler)
    func setupCarbonHotkey() {
        // Only register if Cmd+Tab is the configured shortcut
        // Called from main thread, use assumeIsolated
        let isCmdTab = MainActor.assumeIsolated { AppConfig.shared.isCmdTabShortcut }
        guard isCmdTab else {
            debugLog("Cmd+Tab not configured, skipping Carbon hotkey")
            return
        }

        // Unregister existing hotkey if any
        if let existingRef = carbonHotKeyRef {
            UnregisterEventHotKey(existingRef)
            carbonHotKeyRef = nil
        }

        // Define the hotkey: Cmd+Tab
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x57494E42)  // "WINB"
        hotKeyID.id = 1

        // Tab = 48, Cmd = cmdKey
        let keyCode: UInt32 = 48
        let modifiers: UInt32 = UInt32(cmdKey)

        // Register the hotkey
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            carbonHotKeyRef = ref
            debugLog("Carbon Cmd+Tab hotkey registered successfully")

            // Install event handler for the hotkey
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            let handlerCallback: EventHandlerUPP = { (_, event, userData) -> OSStatus in
                guard let appDelegate = globalAppDelegate else { return noErr }

                DispatchQueue.main.async {
                    // Check if settings window is focused - don't handle if so
                    if appDelegate.settingsWindow?.isKeyWindow == true {
                        return
                    }

                    if appDelegate.window.isVisible {
                        // Second+ press: enter cycling mode
                        appDelegate.isTabCycling = true
                        WindowManager.shared.isCycling = true
                        appDelegate.selectNextWindow()
                    } else {
                        // First press: save focus and show sidebar
                        // showSidebar() selects the current window (index 0)
                        appDelegate.savePreviousFocus()
                        appDelegate.showSidebar()
                    }
                }
                return noErr
            }

            var handlerRef: EventHandlerRef?
            InstallEventHandler(
                GetApplicationEventTarget(),
                handlerCallback,
                1,
                &eventType,
                nil,
                &handlerRef
            )
            carbonEventHandler = handlerRef
        } else {
            debugLog("Failed to register Carbon hotkey: \(status)")
        }
    }

    func setupGlobalHotkey() {
        // 1. Set up customizable hotkey via KeyboardShortcuts
        KeyboardShortcuts.onKeyDown(for: .toggleWinby) { [weak self] in
            guard let self = self else { return }

            // KeyboardShortcuts callbacks run on main thread
            MainActor.assumeIsolated {
                // If Cmd+Tab is the configured shortcut, Carbon hotkey handles it instead
                if AppConfig.shared.isCmdTabShortcut {
                    return
                }

                // Check if shift is held for reverse direction
                let goBackward = NSEvent.modifierFlags.contains(.shift)

                if self.window.isVisible {
                    // Second+ press: enter cycling mode
                    self.isTabCycling = true
                    WindowManager.shared.isCycling = true
                    if goBackward {
                        self.selectPreviousWindow()
                    } else {
                        self.selectNextWindow()
                    }
                } else {
                    // First press: save focus and show sidebar
                    // showSidebar() selects the current window (index 0)
                    self.savePreviousFocus()
                    self.showSidebar()
                }
            }
        }

        // 2. Register Carbon hotkey for Cmd+Tab (this takes priority over the system)
        setupCarbonHotkey()

        // 3. Set up CGEventTap to handle Cmd release and Cmd+Shift+Tab
        globalAppDelegate = self

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                return globalAppDelegate?.handleEventTap(proxy: proxy, type: type, event: event) ?? Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            debugLog("Failed to create event tap for Cmd+Tab - accessibility permissions may be needed")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            debugLog("CGEventTap installed successfully for Cmd+Tab")
        }

        // 4. Set up local event monitor to catch hotkey when app has focus
        // This handles the case where the global monitor doesn't fire because the app is active
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Only intercept when sidebar is visible
            guard self.window.isVisible else { return event }

            let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])

            // Check for Cmd+Enter to fullscreen selected window
            if event.keyCode == 36 && eventModifiers == .command {  // 36 = Return key
                if let windowID = WindowManager.shared.selectedWindowID {
                    WindowManager.shared.bringToFront(windowID)
                    WindowManager.shared.toggleFullscreen(windowID)
                    self.didSelectWindow = true
                    self.hideSidebar()
                    return nil  // Consume the event
                }
            }

            // Check if this matches the configured hotkey
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleWinby) {
                // Compare key and modifiers
                if let key = shortcut.key,
                   event.keyCode == key.rawValue,
                   eventModifiers == shortcut.modifiers {
                    // Hotkey pressed while sidebar visible - hide it
                    self.hideSidebar()
                    return nil  // Consume the event
                }
            }

            return event
        }
    }

    func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Check if Cmd+Tab is configured as the shortcut
        // Event tap callback runs on main thread, so use assumeIsolated to avoid deadlock
        let (shouldInterceptCmdTab, settingsIsKey): (Bool, Bool)
        if Thread.isMainThread {
            shouldInterceptCmdTab = MainActor.assumeIsolated {
                AppConfig.shared.isCmdTabShortcut
            }
            settingsIsKey = settingsWindow?.isKeyWindow ?? false
        } else {
            shouldInterceptCmdTab = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    AppConfig.shared.isCmdTabShortcut
                }
            }
            settingsIsKey = settingsWindow?.isKeyWindow ?? false
        }

        // If settings window is focused, intercept Cmd+Tab but post synthetic event for recorder
        if settingsIsKey && type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isTab = keyCode == 48
            let isCmd = flags.contains(.maskCommand)

            if isTab && isCmd {
                // Post synthetic key event to the app so recorder can capture it
                DispatchQueue.main.async {
                    if let syntheticEvent = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0,
                        context: nil,
                        characters: "\t",
                        charactersIgnoringModifiers: "\t",
                        isARepeat: false,
                        keyCode: 48
                    ) {
                        NSApp.sendEvent(syntheticEvent)
                    }
                }
                // Block system Cmd+Tab
                return nil
            }
        }

        // Handle modifier key changes (detect when Cmd is released)
        if type == .flagsChanged {
            let flags = event.flags

            // If Cmd is released while in cycling mode (second+ Tab was pressed), activate
            if isTabCycling && !flags.contains(.maskCommand) {
                DispatchQueue.main.async { [weak self] in
                    self?.activateSelectedAndHide()
                }
            }
            // If Cmd is released after just one Tab (not cycling), window stays open
            return Unmanaged.passRetained(event)
        }

        // Handle key down events
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // Tab key = 48
            let isTab = keyCode == 48
            let isCmd = flags.contains(.maskCommand)
            let isShift = flags.contains(.maskShift)
            let hasOtherModifiers = flags.contains(.maskAlternate) || flags.contains(.maskControl)

            // Only intercept Cmd+Tab (or Cmd+Shift+Tab) if it's the configured shortcut
            // and no other modifiers are pressed
            if isTab && isCmd && !hasOtherModifiers && shouldInterceptCmdTab {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    if !self.window.isVisible {
                        // First shortcut press: show sidebar
                        // showSidebar() selects the current window (index 0)
                        // Do NOT enter cycling mode yet - release will keep window open
                        self.showSidebar()
                    } else {
                        // Second+ shortcut press while visible: NOW enter cycling mode
                        self.isTabCycling = true
                        WindowManager.shared.isCycling = true
                        if isShift {
                            self.selectPreviousWindow()
                        } else {
                            self.selectNextWindow()
                        }
                    }
                }
                // Consume the event (don't pass to system)
                return nil
            }
        }

        // Pass other events through
        return Unmanaged.passRetained(event)
    }
}
