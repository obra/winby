import SwiftUI
import ScreenCaptureKit

struct SidebarView: View {
    @ObservedObject var manager = WindowManager.shared
    @ObservedObject var config = AppConfig.shared
    @State private var thumbnails: [UInt32: NSImage] = [:]
    @State private var searchText = ""
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var isSearchingContent = false
    @State private var showDebugPanel = false
    @State private var debugContent = ""
    @FocusState private var isSearchFocused: Bool

    var filteredWindows: [WindowInfo] {
        // Filter out background tabs if setting is disabled
        let baseWindows = AppConfig.shared.showBackgroundTabs
            ? manager.windows
            : manager.windows.filter { $0.parentWindowID == nil }

        // Trim spaces - they're used as term separators, not search characters
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        if trimmedSearch.isEmpty {
            return baseWindows
        }
        // Filter by fuzzy match (keep original window order)
        let query = trimmedSearch.lowercased()
        return baseWindows.filter { window in
            let titleScore = fuzzyMatch(query: query, in: window.displayTitle.lowercased())
            let appScore = fuzzyMatch(query: query, in: window.appName.lowercased())
            let contentScore = manager.contentMatches[window.windowID] ?? 0

            // Window matches if title/app matches OR content matches
            return max(titleScore, appScore) > 0 || contentScore > 0
        }
    }

    /// Windows on the current space
    var currentSpaceWindows: [WindowInfo] {
        filteredWindows.filter { $0.isOnCurrentSpace }
    }

    /// Windows on other spaces
    var otherSpaceWindows: [WindowInfo] {
        filteredWindows.filter { !$0.isOnCurrentSpace }
    }

    /// Trigger debounced content search
    func triggerContentSearch() {
        contentSearchTask?.cancel()
        contentSearchTask = Task {
            // Debounce: wait 300ms before searching
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
            guard !trimmedSearch.isEmpty else { return }

            await MainActor.run { isSearchingContent = true }
            await manager.searchContent(query: trimmedSearch)
            await MainActor.run { isSearchingContent = false }
        }
    }

    /// Fuzzy match a single term against text - returns score (0 = no match, higher = better)
    func fuzzyMatchTerm(_ term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }

        var score = 0
        var termIndex = term.startIndex
        var textIndex = text.startIndex
        var consecutiveBonus = 0

        while termIndex < term.endIndex && textIndex < text.endIndex {
            if term[termIndex] == text[textIndex] {
                score += 1 + consecutiveBonus
                consecutiveBonus += 1  // Bonus for consecutive matches
                termIndex = term.index(after: termIndex)
            } else {
                consecutiveBonus = 0
            }
            textIndex = text.index(after: textIndex)
        }

        // Only return score if we matched all term characters
        return termIndex == term.endIndex ? score : 0
    }

    /// Fuzzy match query against text. Space-separated terms are matched independently.
    /// All terms must match for a non-zero score.
    func fuzzyMatch(query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }

        let terms = query.split(separator: " ").map { String($0) }
        guard !terms.isEmpty else { return 0 }

        var totalScore = 0
        for term in terms {
            let termScore = fuzzyMatchTerm(term, in: text)
            if termScore == 0 {
                return 0  // All terms must match
            }
            totalScore += termScore
        }

        return totalScore
    }

    /// Flat list of windows for keyboard navigation (matches visual order)
    var flatWindowList: [WindowInfo] {
        // Current space windows first, then other spaces
        currentSpaceWindows + otherSpaceWindows
    }

    func selectNext() {
        let list = flatWindowList
        guard !list.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = list.firstIndex(where: { $0.windowID == current }) {
            let nextIdx = min(idx + 1, list.count - 1)
            manager.selectedWindowID = list[nextIdx].windowID
        } else {
            manager.selectedWindowID = list[0].windowID
        }
    }

    func selectPrevious() {
        let list = flatWindowList
        guard !list.isEmpty else { return }

        if let current = manager.selectedWindowID,
           let idx = list.firstIndex(where: { $0.windowID == current }) {
            let prevIdx = max(idx - 1, 0)
            manager.selectedWindowID = list[prevIdx].windowID
        } else {
            manager.selectedWindowID = list[0].windowID
        }
    }

    func activateSelected() {
        // Use selected window, or first visible window if nothing selected
        let windowID = manager.selectedWindowID ?? filteredWindows.first?.windowID

        if let windowID = windowID {
            manager.bringToFront(windowID)
            searchText = ""
            // Mark that we selected a window (so focus isn't restored to previous app)
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.didSelectWindow = true
                appDelegate.hideSidebar()
            }
        }
    }

    /// Update debug content when selection changes
    func updateDebugContent() {
        guard showDebugPanel, let windowID = manager.selectedWindowID,
              let window = manager.windows.first(where: { $0.windowID == windowID }) else {
            debugContent = "No window selected"
            return
        }

        debugContent = "Loading..."

        // Fetch content in background
        Task {
            var content = "=== \(window.appName): \(window.title) ===\n\n"

            // Get cached content
            if let cached = manager.contentCache[windowID] {
                content += "📋 CACHED CONTENT (\(cached.count) chars):\n"
                content += String(cached.prefix(3000)) + "\n\n"
            } else {
                content += "📋 CACHED: No cached content\n\n"
            }

            // Get fresh OCR (full-size capture)
            if let ocrText = await manager.getWindowContentViaOCR(windowID: windowID) {
                content += "🔍 FRESH OCR (\(ocrText.count) chars):\n"
                content += String(ocrText.prefix(3000)) + "\n\n"
            } else {
                content += "🔍 OCR: No text found (window may be off-screen)\n\n"
            }

            // Get fresh AX content
            if let axContent = manager.getWindowContent(windowID: windowID, pid: window.pid) {
                content += "♿ AX API (\(axContent.count) chars):\n"
                content += String(axContent.prefix(3000)) + "\n"
            } else {
                content += "♿ AX API: No content found\n"
            }

            await MainActor.run {
                debugContent = content
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main sidebar
            VStack(spacing: 0) {
                // Search
                HStack {
                    TextField("Search windows...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onChange(of: searchText) { _, newValue in
                            if newValue.isEmpty {
                                manager.contentMatches = [:]
                                contentSearchTask?.cancel()
                            } else {
                                triggerContentSearch()
                            }
                            // Always ensure we have a valid selection from filtered results
                            // (handles both filtering out current selection AND other-space only results)
                            let currentValid = manager.selectedWindowID.flatMap { id in
                                filteredWindows.contains(where: { $0.windowID == id })
                            } ?? false
                            if !currentValid, let first = filteredWindows.first {
                                manager.selectedWindowID = first.windowID
                            }
                        }

                    if isSearchingContent {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }

                    // Debug toggle (only shown when debug mode enabled)
                    if config.debugMode {
                        Button(action: {
                            showDebugPanel.toggle()
                            if showDebugPanel { updateDebugContent() }
                        }) {
                            Image(systemName: showDebugPanel ? "ladybug.fill" : "ladybug")
                                .foregroundColor(showDebugPanel ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle debug panel")
                    }
                }
                .padding(8)

                Divider()

            // Window list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        // Current space windows
                        ForEach(currentSpaceWindows) { window in
                            WindowRow(
                                window: window,
                                isSelected: manager.selectedWindowID == window.windowID,
                                hasContentMatch: manager.contentMatches[window.windowID] != nil,
                                thumbnail: thumbnails[window.windowID],
                                onSelect: {
                                    manager.selectedWindowID = window.windowID
                                    manager.bringToFront(window.windowID)
                                    searchText = ""
                                    // Mark selection and hide sidebar
                                    if let appDelegate = NSApp.delegate as? AppDelegate {
                                        appDelegate.didSelectWindow = true
                                        appDelegate.hideSidebar()
                                    }
                                }
                            )
                            .id(window.id)  // Use String id for SwiftUI identity
                        }

                        // Other spaces section (if any)
                        if !otherSpaceWindows.isEmpty {
                            HStack {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 1)
                                Text("Other Spaces")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)

                            ForEach(otherSpaceWindows) { window in
                                WindowRow(
                                    window: window,
                                    isSelected: manager.selectedWindowID == window.windowID,
                                    hasContentMatch: manager.contentMatches[window.windowID] != nil,
                                    thumbnail: thumbnails[window.windowID],
                                    onSelect: {
                                        manager.selectedWindowID = window.windowID
                                        manager.bringToFront(window.windowID)
                                        searchText = ""
                                        // Mark selection and hide sidebar
                                        if let appDelegate = NSApp.delegate as? AppDelegate {
                                            appDelegate.didSelectWindow = true
                                            appDelegate.hideSidebar()
                                        }
                                    }
                                )
                                .id(window.id)
                                .opacity(0.7)  // Slightly dimmed to indicate different space
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 50)  // Extra space so last item can scroll into view
                }
                .onChange(of: manager.selectedWindowID) { _, newValue in
                    if let windowID = newValue,
                       let window = flatWindowList.first(where: { $0.windowID == windowID }) {
                        // Use bottom anchor when near end of list for better visibility
                        let isNearEnd = flatWindowList.last?.windowID == windowID
                        withAnimation {
                            proxy.scrollTo(window.id, anchor: isNearEnd ? .bottom : .center)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(manager.windows.count) windows")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
                .padding(8)
            }
            .frame(width: 280)
            .background(Color.clear)

            // Debug panel (shown when debug mode is on)
            if showDebugPanel {
                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Debug: Content Extraction")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button("Refresh") {
                            updateDebugContent()
                        }
                        .font(.system(size: 10))
                    }
                    .padding(8)

                    Divider()

                    ScrollView {
                        Text(debugContent)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                .frame(width: 400)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .onKeyPress(.downArrow) {
            selectNext()
            if showDebugPanel { updateDebugContent() }
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectPrevious()
            if showDebugPanel { updateDebugContent() }
            return .handled
        }
        .onKeyPress(.return) {
            activateSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            if searchText.isEmpty {
                // If search is empty, dismiss sidebar
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.hideSidebar()
                }
            } else {
                // Otherwise just clear search
                searchText = ""
                manager.selectedWindowID = nil
            }
            return .handled
        }
        .onAppear {
            loadThumbnails()
        }
        .onChange(of: manager.windows) {
            loadThumbnails()
        }
        .onChange(of: manager.selectedWindowID) {
            if showDebugPanel { updateDebugContent() }
        }
        .onChange(of: manager.sidebarResetTrigger) {
            // Reset state when sidebar is hidden
            searchText = ""
            manager.selectedWindowID = nil
            manager.contentMatches = [:]
        }
    }

    func loadThumbnails() {
        Task {
            var newThumbnails = thumbnails

            // Get all SC windows ONCE (expensive call)
            let scWindows: [SCWindow]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                scWindows = content.windows
                debugLog("loadThumbnails: got \(scWindows.count) SCWindows")
            } catch {
                debugLog("loadThumbnails: SCShareableContent failed: \(error)")
                scWindows = []
            }

            // Build lookup map
            let scWindowMap = Dictionary(uniqueKeysWithValues: scWindows.map { ($0.windowID, $0) })

            // Process windows in parallel with limited concurrency
            await withTaskGroup(of: (UInt32, NSImage?).self) { group in
                for window in manager.windows {
                    let isBackgroundTab = window.parentWindowID != nil
                    // Skip if we already have a thumbnail for background tabs
                    if isBackgroundTab && newThumbnails[window.windowID] != nil {
                        continue
                    }

                    group.addTask {
                        let thumb = await self.captureThumbnail(
                            window: window,
                            scWindow: scWindowMap[window.windowID],
                            maxSize: CGSize(width: 200, height: 150)
                        )
                        return (window.windowID, thumb)
                    }
                }

                for await (windowID, thumb) in group {
                    if let thumb = thumb {
                        newThumbnails[windowID] = thumb
                    }
                }
            }

            // Keep thumbnails for current windows
            let currentIDs = Set(manager.windows.map { $0.windowID })
            newThumbnails = newThumbnails.filter { currentIDs.contains($0.key) }

            await MainActor.run {
                thumbnails = newThumbnails
            }
        }
    }

    /// Capture a single thumbnail using provided SCWindow (avoids repeated SCShareableContent calls)
    /// Also caches the full-size image for instant preview loading
    func captureThumbnail(window: WindowInfo, scWindow: SCWindow?, maxSize: CGSize) async -> NSImage? {
        // For sensitive apps (password managers), return placeholder instead of real screenshot
        if manager.isSensitiveApp(pid: window.pid, appName: window.appName) {
            let appIcon = NSRunningApplication(processIdentifier: window.pid)?.icon
            let aspectRatio = window.frame.width / window.frame.height
            let placeholderSize: CGSize
            if aspectRatio > maxSize.width / maxSize.height {
                placeholderSize = CGSize(width: maxSize.width, height: maxSize.width / aspectRatio)
            } else {
                placeholderSize = CGSize(width: maxSize.height * aspectRatio, height: maxSize.height)
            }
            return manager.generatePlaceholderWindow(title: window.title, appIcon: appIcon, size: placeholderSize)
        }

        // For background tabs, check tab screenshot cache first
        if window.parentWindowID != nil {
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            if let cached = manager.getTabScreenshot(key: cacheKey) {
                return cached
            }
            // Background tabs can't be captured directly - fall back to app icon
            if let app = NSRunningApplication(processIdentifier: window.pid),
               let icon = app.icon {
                return icon
            }
            return nil
        }

        var fullImage: NSImage?

        // Try ScreenCaptureKit if we have an SCWindow - capture at window's actual size
        if let scWindow = scWindow {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                // Capture at window's actual resolution (2x for retina)
                let windowSize = scWindow.frame.size
                config.width = Int(windowSize.width * 2)
                config.height = Int(windowSize.height * 2)
                config.scalesToFit = false
                config.showsCursor = false

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                fullImage = NSImage(cgImage: cgImage, size: windowSize)
            } catch {
                // Fall through to private API
            }
        }

        // Fallback: try private API at full size
        if fullImage == nil {
            if let cgImage = manager.captureWindowViaPrivateAPI(windowID: window.windowID, fullSize: true) {
                let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                fullImage = NSImage(cgImage: cgImage, size: size)
            }
        }

        // Cache full image for preview panel and tab screenshot cache
        if let fullImage = fullImage {
            manager.setFullImage(for: window.windowID, image: fullImage)

            // Also cache in tab screenshot cache for when this becomes a background tab
            let cacheKey = manager.tabCacheKey(pid: window.pid, title: window.title)
            manager.setTabScreenshot(key: cacheKey, image: fullImage)

            // Create thumbnail from full image
            let fullSize = fullImage.size
            let scale = min(maxSize.width / fullSize.width, maxSize.height / fullSize.height)
            let scaledSize = CGSize(width: fullSize.width * scale, height: fullSize.height * scale)
            let thumbnail = NSImage(size: scaledSize)
            thumbnail.lockFocus()
            fullImage.draw(in: NSRect(origin: .zero, size: scaledSize))
            thumbnail.unlockFocus()
            return thumbnail
        }

        // Final fallback: app icon
        if let app = NSRunningApplication(processIdentifier: window.pid),
           let icon = app.icon {
            return icon
        }

        return nil
    }
}
