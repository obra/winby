import SwiftUI
import KeyboardShortcuts

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case accessibility
    case screenRecording
    case hotkey
    case launchAtLogin
    case ready
}

struct OnboardingView: View {
    @ObservedObject var config = AppConfig.shared
    @State private var currentStep: OnboardingStep = .welcome
    @State private var furthestStep: OnboardingStep = .welcome  // Track furthest step to prevent auto-forward after Back
    @State private var permissionCheckTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            ZStack {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    if step == currentStep {
                        stepContent(for: step)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            // Progress dots - fixed at bottom
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 20)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            startPermissionPolling()
        }
        .onDisappear {
            permissionCheckTimer?.invalidate()
        }
    }

    @ViewBuilder
    func stepContent(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            welcomeStep
        case .accessibility:
            accessibilityStep
        case .screenRecording:
            screenRecordingStep
        case .hotkey:
            hotkeyStep
        case .launchAtLogin:
            launchAtLoginStep
        case .ready:
            readyStep
        }
    }

    // MARK: - Step Views

    var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Welcome to Winby")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("A faster way to switch windows — with search, previews, and content search.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            Button(action: { advanceTo(.accessibility) }) {
                Text("Get Started")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var accessibilityStep: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Image(systemName: "accessibility")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                if config.hasAccessibilityPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                        .offset(x: 36, y: 28)
                }
            }

            Text("Accessibility Access")
                .font(.title)
                .fontWeight(.bold)

            Text("Winby needs Accessibility access to manage windows and respond to your keyboard shortcut.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            if config.hasAccessibilityPermission {
                Button(action: { advanceTo(.screenRecording) }) {
                    Text("Continue")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: { config.openAccessibilitySettings() }) {
                    Text("Open System Settings")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Grant access, then return here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var screenRecordingStep: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Image(systemName: "camera.metering.spot")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                if config.hasScreenRecordingPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                        .offset(x: 36, y: 28)
                }
            }

            Text("Screen Recording")
                .font(.title)
                .fontWeight(.bold)

            Text("Screen Recording lets Winby search by what's visible in your windows.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            if config.hasScreenRecordingPermission {
                Button(action: { advanceTo(.hotkey) }) {
                    Text("Continue")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: { config.openScreenRecordingSettings() }) {
                    Text("Open System Settings")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Grant access, then return here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button(action: { currentStep = .accessibility }) {
                    Text("Back")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var hotkeyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Choose Your Hotkey")
                .font(.title)
                .fontWeight(.bold)

            Text("Pick a keyboard shortcut to activate Winby.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            // Wrap recorder with tap gesture to clear shortcut when clicked
            // This makes it easier to change an existing shortcut
            KeyboardShortcuts.Recorder("", name: .toggleWinby)
                .padding(.vertical, 8)
                .onTapGesture {
                    // Clear the shortcut so the recorder enters recording mode
                    KeyboardShortcuts.reset(.toggleWinby)
                }

            Text("Tip: You can use Cmd+Tab, but it requires granting Accessibility permission again after setting it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer()

            Button(action: { advanceTo(.launchAtLogin) }) {
                Text("Continue")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: { currentStep = .screenRecording }) {
                Text("Back")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var launchAtLoginStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "power")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Launch at Login")
                .font(.title)
                .fontWeight(.bold)

            Text("Start Winby automatically when you log in.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Toggle("Launch at Login", isOn: $config.launchAtLogin)
                .toggleStyle(.switch)
                .labelsHidden()
                .padding(.vertical, 8)

            Spacer()

            Button(action: { advanceTo(.ready) }) {
                Text("Continue")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: { currentStep = .hotkey }) {
                Text("Back")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    var readyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Press \(config.hotkeyDescription) to open Winby anytime.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()

            Button(action: {
                config.hasCompletedOnboarding = true
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.hideOnboardingWindow()
                }
            }) {
                Text("Start Using Winby")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding(40)
    }

    // MARK: - Permission Polling

    func startPermissionPolling() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // Auto-advance when permissions are granted, but only if user hasn't already passed that step
            // (prevents auto-forwarding when user clicks Back)
            if currentStep == .accessibility && config.hasAccessibilityPermission && furthestStep.rawValue < OnboardingStep.screenRecording.rawValue {
                advanceTo(.screenRecording)
            } else if currentStep == .screenRecording && config.hasScreenRecordingPermission && furthestStep.rawValue < OnboardingStep.hotkey.rawValue {
                advanceTo(.hotkey)
            }
        }
    }

    func advanceTo(_ step: OnboardingStep) {
        withAnimation {
            currentStep = step
            if step.rawValue > furthestStep.rawValue {
                furthestStep = step
            }
        }
    }
}
