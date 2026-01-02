import Cocoa
import Vision
import ScreenCaptureKit

// MARK: - Content Search and OCR

extension WindowManager {
    func quickImageHash(_ cgImage: CGImage) -> Int {
        var hasher = Hasher()
        // Sample a grid of pixels across the image
        let width = cgImage.width
        let height = cgImage.height
        let stepX = max(width / 16, 1)
        let stepY = max(height / 16, 1)

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return 0
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                // Sample RGB values
                if bytesPerPixel >= 3 {
                    hasher.combine(bytes[offset])      // R
                    hasher.combine(bytes[offset + 1])  // G
                    hasher.combine(bytes[offset + 2])  // B
                }
            }
        }

        return hasher.finalize()
    }

    /// Extract text from an image using Vision OCR
    func ocrImage(_ image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            debugLog("OCR: Failed to get CGImage from NSImage")
            return nil
        }

        debugLog("OCR: Processing image \(cgImage.width)x\(cgImage.height)")

        var recognizedText = ""
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                debugLog("OCR error: \(error)")
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            // Sort observations by Y position (top to bottom), then X (left to right)
            let sorted = observations.sorted { obs1, obs2 in
                // Vision uses normalized coords where Y=1 is top, Y=0 is bottom
                if abs(obs1.boundingBox.midY - obs2.boundingBox.midY) > 0.02 {
                    return obs1.boundingBox.midY > obs2.boundingBox.midY  // Higher Y = higher on screen
                }
                return obs1.boundingBox.midX < obs2.boundingBox.midX
            }

            for observation in sorted {
                if let candidate = observation.topCandidates(1).first {
                    if !recognizedText.isEmpty { recognizedText += " " }
                    recognizedText += candidate.string
                }
            }
        }
        request.recognitionLevel = .accurate  // Better quality
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3  // Latest revision

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            debugLog("OCR handler error: \(error)")
            return nil
        }

        debugLog("OCR: Got \(recognizedText.count) chars")
        return recognizedText.isEmpty ? nil : recognizedText
    }

    /// Get content via OCR from a full-size window capture
    /// Returns nil if capture failed, returns cached content if screenshot unchanged
    func getWindowContentViaOCR(windowID: UInt32) async -> String? {
        // Get window info
        guard let window = windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        // Skip OCR for sensitive apps (password managers)
        if isSensitiveApp(pid: window.pid, appName: window.appName) {
            return nil
        }

        let cacheKey = tabCacheKey(pid: window.pid, title: window.title)

        // For background tabs, check tabOcrCache first
        if window.parentWindowID != nil {
            if let cached = getTabOcr(key: cacheKey) {
                return cached
            }
            // Background tabs can't be captured - no content available
            return nil
        }

        // Try to capture the window - first via ScreenCaptureKit, then via private API
        var cgImage: CGImage?

        // Try ScreenCaptureKit first (works for most on-screen windows)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                // Use actual window size or cap at reasonable resolution for OCR
                config.width = min(Int(scWindow.frame.width), 1920)
                config.height = min(Int(scWindow.frame.height), 1080)
                config.scalesToFit = false
                config.showsCursor = false

                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch {
            debugLog("OCR: ScreenCaptureKit failed for window \(windowID): \(error)")
        }

        // Fallback: try private API (works for minimized/other-space windows)
        if cgImage == nil {
            debugLog("OCR: Trying private API for window \(windowID)")
            cgImage = captureWindowViaPrivateAPI(windowID: windowID, fullSize: true)
        }

        guard let capturedImage = cgImage else {
            debugLog("OCR: All capture methods failed for window \(windowID)")
            return nil
        }

        // Check if screenshot changed - if not, use cached content
        let newHash = quickImageHash(capturedImage)
        if let oldHash = screenshotHashes[windowID], oldHash == newHash {
            // Screenshot unchanged, return cached content
            if let cached = contentCache[windowID] {
                debugLog("OCR: Screenshot unchanged for window \(windowID), using cache")
                return cached
            }
        }

        // Screenshot changed or no cache, run OCR
        let nsImage = NSImage(cgImage: capturedImage, size: NSSize(width: capturedImage.width, height: capturedImage.height))
        if let text = ocrImage(nsImage) {
            // Update hash for next comparison
            screenshotHashes[windowID] = newHash
            // Also cache by pid+title for when this becomes a background tab
            setTabOcr(key: cacheKey, text: text)
            return text
        }
        return nil
    }

    /// Debug: dump what content we can get from all windows
    func debugContentFetch() {
        debugLog("=== Content fetch debug ===")
        for window in windows {
            if let content = getWindowContent(windowID: window.windowID, pid: window.pid) {
                let preview = String(content.prefix(200)).replacingOccurrences(of: "\n", with: "\\n")
                debugLog("[\(window.appName)] '\(window.title)': \(content.count) chars - '\(preview)...'")
            } else {
                debugLog("[\(window.appName)] '\(window.title)': NO CONTENT")
            }
        }
        debugLog("=== End content debug ===")
    }

    /// Background queue for content indexing
    private static let indexQueue = DispatchQueue(label: "content-index", qos: .utility, attributes: .concurrent)

    /// Index content for all windows in background (10 at a time, using OCR)
    func indexContentInBackground() {
        guard !isIndexing else { return }
        isIndexing = true

        let now = Date()
        let refreshInterval: TimeInterval = 10  // Re-index on-screen windows every 10 seconds

        // Index windows that:
        // 1. Are not sensitive apps (password managers), AND
        // 2. Have no content and haven't failed, OR
        // 3. Are on-screen and haven't been indexed recently (content may have changed)
        let windowsCopy = windows.filter { window in
            // Skip sensitive apps entirely
            if isSensitiveApp(pid: window.pid, appName: window.appName) {
                return false
            }
            if contentCache[window.windowID] == nil && !contentFailed.contains(window.windowID) {
                return true  // Never indexed
            }
            if window.isOnScreen, let lastTime = lastIndexed[window.windowID],
               now.timeIntervalSince(lastTime) > refreshInterval {
                return true  // On-screen and stale
            }
            return false
        }

        guard !windowsCopy.isEmpty else {
            isIndexing = false
            return
        }

        Task {
            await withTaskGroup(of: Void.self) { group in
                let semaphore = AsyncSemaphore(limit: 10)

                for window in windowsCopy {
                    group.addTask { [weak self] in
                        await semaphore.wait()

                        guard let self = self else {
                            await semaphore.signal()
                            return
                        }

                        // Only try OCR on on-screen windows (can't capture off-screen)
                        if window.isOnScreen {
                            if let content = await self.getWindowContentViaOCR(windowID: window.windowID), content.count > 20 {
                                await MainActor.run {
                                    self.contentCache[window.windowID] = content
                                    self.lastIndexed[window.windowID] = Date()
                                }
                                await semaphore.signal()
                                return
                            }
                        }

                        // Fall back to AX API (works for all windows)
                        if let content = self.getWindowContent(windowID: window.windowID, pid: window.pid), content.count > 20 {
                            await MainActor.run {
                                self.contentCache[window.windowID] = content
                                self.lastIndexed[window.windowID] = Date()
                            }
                        } else if !window.isOnScreen {
                            // Only mark as failed if off-screen (on-screen might succeed later)
                            _ = await MainActor.run {
                                self.contentFailed.insert(window.windowID)
                            }
                        }

                        await semaphore.signal()
                    }
                }
            }

            await MainActor.run { [weak self] in
                self?.isIndexing = false
            }
        }
    }

    /// Search cached content only (instant, never blocks)
    func searchContent(query: String) async {
        guard !query.isEmpty else {
            contentMatches = [:]
            return
        }

        let queryLower = query.lowercased()
        let terms = queryLower.split(separator: " ").map { String($0) }

        var newMatches: [UInt32: Int] = [:]

        // Search only cached content - instant
        for window in windows {
            guard let content = contentCache[window.windowID] else { continue }

            let contentLower = content.lowercased()
            var totalScore = 0
            var allMatch = true

            for term in terms {
                if contentLower.contains(term) {
                    totalScore += term.count * 2
                } else {
                    allMatch = false
                    break
                }
            }

            if allMatch && totalScore > 0 {
                newMatches[window.windowID] = totalScore
            }
        }

        contentMatches = newMatches
    }

    /// Clear content cache for a window (call when window content might have changed)
    func invalidateContentCache(for windowID: UInt32) {
        contentCache.removeValue(forKey: windowID)
        contentFailed.remove(windowID)
    }

    /// Clear all content caches
    func clearContentCache() {
        contentCache.removeAll()
        contentMatches.removeAll()
        contentFailed.removeAll()
    }
}
