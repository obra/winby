import Cocoa

// MARK: - Main

debugLog("WindowManager starting up")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Menubar app style
debugLog("App configured, running main loop")
app.run()
