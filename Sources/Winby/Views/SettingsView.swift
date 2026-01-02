import SwiftUI
import KeyboardShortcuts
import Sparkle

struct SettingsView: View {
    @ObservedObject var config = AppConfig.shared

    var body: some View {
        Form {
            Section("Activation Shortcut") {
                KeyboardShortcuts.Recorder("Show Winby:", name: .toggleWinby)
                    .help("Press Cmd+Tab here to use it as your shortcut")
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $config.launchAtLogin)
                Toggle("Show Background Tabs", isOn: $config.showBackgroundTabs)
                    .help("Show non-active tabs as separate entries in the window list")
            }

            Section("Experiments") {
                Toggle("Cache Background Tabs", isOn: $config.cacheBackgroundTabs)
                    .help("Cycle through tabs after dismissal to capture screenshots (causes brief flickering)")
                    .disabled(!config.showBackgroundTabs)
                Toggle("Debug Mode", isOn: $config.debugMode)
                    .help("Show debug controls and log to /tmp/wm_debug.log")
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 250)
        .padding()
    }
}
