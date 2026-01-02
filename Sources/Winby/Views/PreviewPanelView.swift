import SwiftUI

// MARK: - Preview Panel View

struct PreviewPanelView: View {
    @ObservedObject var manager = WindowManager.shared
    @State private var previewImage: NSImage?
    @State private var displayedImage: NSImage?  // For crossfade animation
    @State private var loadingTask: Task<Void, Never>?
    @State private var isHovering = false
    @State private var isDraggingWindow = false
    @State private var isResizing = false
    @State private var imageAspectRatio: CGFloat = 16.0 / 9.0
    @State private var dragStartLocation: NSPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            if let image = displayedImage {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        // Resize handle overlaid on the image itself
                        if isHovering || isResizing {
                            ResizeHandle(isResizing: $isResizing, aspectRatio: imageAspectRatio)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Don't move window while resizing
                                guard !isResizing else { return }
                                guard let window = (NSApp.delegate as? AppDelegate)?.previewWindow else { return }
                                if !isDraggingWindow {
                                    isDraggingWindow = true
                                    dragStartLocation = NSEvent.mouseLocation
                                }
                                // Move window based on mouse delta
                                let currentMouse = NSEvent.mouseLocation
                                let deltaX = currentMouse.x - dragStartLocation.x
                                let deltaY = currentMouse.y - dragStartLocation.y
                                let currentFrame = window.frame
                                window.setFrameOrigin(NSPoint(
                                    x: currentFrame.origin.x + deltaX,
                                    y: currentFrame.origin.y + deltaY
                                ))
                                dragStartLocation = currentMouse
                            }
                            .onEnded { _ in
                                isDraggingWindow = false
                            }
                    )
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                // Focus the selected window
                                if let windowID = manager.selectedWindowID {
                                    manager.bringToFront(windowID)
                                    if let appDelegate = NSApp.delegate as? AppDelegate {
                                        appDelegate.didSelectWindow = true
                                        appDelegate.hideSidebar()
                                    }
                                }
                            }
                    )
                    .id(displayedImage)  // Force view recreation for transition
                    .transition(.opacity)
            } else {
                // Show app icon as placeholder while loading
                if let windowID = manager.selectedWindowID,
                   let window = manager.windows.first(where: { $0.windowID == windowID }),
                   let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                        .opacity(0.5)
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: displayedImage)
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: manager.selectedWindowID) { _, newValue in
            loadPreview(for: newValue)
        }
        .onChange(of: previewImage) { _, newImage in
            // Resize window to fit new image, then crossfade
            if let image = newImage {
                resizeWindowToFitImage(image)
                imageAspectRatio = image.size.width / image.size.height
            }
            displayedImage = newImage
        }
        .onAppear {
            loadPreview(for: manager.selectedWindowID)
        }
    }

    private func resizeWindowToFitImage(_ image: NSImage) {
        guard let window = (NSApp.delegate as? AppDelegate)?.previewWindow else { return }

        let imageSize = image.size
        guard imageSize.width > 0 && imageSize.height > 0 else { return }

        // Calculate target size - fit within screen bounds
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let maxWidth = screen.visibleFrame.width * 0.6
        let maxHeight = screen.visibleFrame.height * 0.7

        let imageAspect = imageSize.width / imageSize.height
        var targetWidth: CGFloat
        var targetHeight: CGFloat

        if imageAspect > maxWidth / maxHeight {
            // Image is wider - constrain by width
            targetWidth = min(imageSize.width, maxWidth)
            targetHeight = targetWidth / imageAspect
        } else {
            // Image is taller - constrain by height
            targetHeight = min(imageSize.height, maxHeight)
            targetWidth = targetHeight * imageAspect
        }

        // Ensure minimum size
        targetWidth = max(200, targetWidth)
        targetHeight = max(150, targetHeight)

        // Keep top-left corner fixed
        let currentFrame = window.frame
        let topY = currentFrame.origin.y + currentFrame.height
        let newY = topY - targetHeight

        window.setFrame(
            NSRect(x: currentFrame.origin.x, y: newY, width: targetWidth, height: targetHeight),
            display: true
        )
    }

    private func loadPreview(for windowID: UInt32?) {
        // Cancel any in-progress load
        loadingTask?.cancel()

        guard let windowID = windowID else {
            previewImage = nil
            return
        }

        // Clear immediately if we don't have a cached image
        // This prevents showing stale preview for windows without screenshots
        // Check both fullImageCache and tabScreenshotCache
        var hasCachedImage = manager.getFullImage(for: windowID) != nil
        if !hasCachedImage, let window = manager.windows.first(where: { $0.windowID == windowID }) {
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            hasCachedImage = manager.getTabScreenshot(key: cacheKey) != nil
        }
        if !hasCachedImage {
            previewImage = nil
        }

        loadingTask = Task {
            let image = await captureWindowImage(windowID: windowID)
            if !Task.isCancelled {
                await MainActor.run {
                    previewImage = image  // Will be nil if capture failed
                }
            }
        }
    }

    private func captureWindowImage(windowID: UInt32) async -> NSImage? {
        // Check full image cache first - populated during thumbnail loading
        if let cached = manager.getFullImage(for: windowID) {
            return cached
        }

        // For background tabs, check tab screenshot cache
        if let window = manager.windows.first(where: { $0.windowID == windowID }),
           window.parentWindowID != nil {
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            if let cached = manager.getTabScreenshot(key: cacheKey) {
                return cached
            }
            // Background tabs can't be captured - generate placeholder window
            let appIcon = NSRunningApplication(processIdentifier: window.pid)?.icon
            // Use parent window's actual frame (tabs have same size as parent)
            let parentFrame = manager.windows.first(where: { $0.windowID == window.parentWindowID })?.frame ?? window.frame
            let placeholderSize = CGSize(width: parentFrame.width, height: parentFrame.height)
            return manager.generatePlaceholderWindow(title: window.title, appIcon: appIcon, size: placeholderSize)
        }

        // Try private API - it's fast and works for most windows
        if let cgImage = manager.captureWindowViaPrivateAPI(windowID: windowID, fullSize: true) {
            let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            manager.setFullImage(for: windowID, image: image)
            return image
        }

        return nil
    }
}
