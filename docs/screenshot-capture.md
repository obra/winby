# Screenshot Capture on macOS

Technical documentation for capturing window screenshots programmatically.

## Overview

Winby uses multiple approaches for capturing window screenshots:
1. **ScreenCaptureKit** (preferred) - Modern API, high quality, requires permission
2. **CGWindowListCreateImage** - Works for visible windows, lower overhead
3. **Private API (CGSHWCaptureWindowList)** - Works for minimized/other-space windows

## ScreenCaptureKit (macOS 12.3+)

The preferred method for capturing visible windows.

### Basic Capture

```swift
import ScreenCaptureKit

// Get available windows
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

// Find specific window
guard let scWindow = content.windows.first(where: { $0.windowID == targetWindowID }) else {
    return nil
}

// Create filter for single window
let filter = SCContentFilter(desktopIndependentWindow: scWindow)

// Configure capture
let config = SCStreamConfiguration()
config.width = Int(scWindow.frame.width * 2)   // 2x for Retina
config.height = Int(scWindow.frame.height * 2)
config.scalesToFit = false  // Capture at actual size
config.showsCursor = false

// Capture
let cgImage = try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: config
)

// Convert to NSImage with proper size
let nsImage = NSImage(cgImage: cgImage, size: scWindow.frame.size)
```

### Thumbnail Capture

For thumbnails, scale to fit a maximum size:

```swift
let maxSize = CGSize(width: 200, height: 150)
config.width = Int(maxSize.width * 2)
config.height = Int(maxSize.height * 2)
config.scalesToFit = true  // Scale window to fit dimensions
```

### Performance Considerations

- `SCShareableContent.excludingDesktopWindows()` is expensive (~1-2 seconds)
- Cache the `SCShareableContent` result and reuse for multiple captures
- Use a map from windowID to SCWindow for quick lookups

```swift
// Cache SCWindows for batch captures
let scWindowMap = Dictionary(
    uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
)
```

## CGWindowListCreateImage

Lower-level API, works without ScreenCaptureKit permission prompt.

```swift
let cgImage = CGWindowListCreateImage(
    .null,  // Capture entire window
    .optionIncludingWindow,
    windowID,
    [.boundsIgnoreFraming, .nominalResolution]
)
```

### Options

- `.boundsIgnoreFraming` - Don't include window shadow
- `.nominalResolution` - Capture at screen resolution (not Retina)
- `.bestResolution` - Capture at highest available resolution

## Private API for Other-Space Windows

Windows on other Spaces or minimized windows can't be captured with public APIs. Use the private `CGSHWCaptureWindowList`:

```swift
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(
    _ cid: Int32,
    _ windowIDs: UnsafeMutablePointer<UInt32>,
    _ count: UInt32,
    _ options: UInt32
) -> CFArray?

func captureWindowViaPrivateAPI(windowID: UInt32, fullSize: Bool = false) -> CGImage? {
    var wid = windowID
    let options: UInt32 = fullSize ? 0x100 : 0x0  // 0x100 = full resolution

    guard let images = CGSHWCaptureWindowList(
        SLSMainConnectionID(),
        &wid,
        1,
        options
    ) as? [CGImage], let image = images.first else {
        return nil
    }

    return image
}
```

### When to Use

- Windows on other Spaces (can't be captured via ScreenCaptureKit)
- Minimized windows
- As fallback when ScreenCaptureKit fails

## Caching Strategy

### In-Memory Caches

Winby maintains multiple caches:

```swift
// Thumbnails by window ID (current windows)
var thumbnailCache: [UInt32: NSImage] = [:]

// Full images by window ID (for preview panel)
var fullImageCache: [UInt32: NSImage] = [:]

// Tab screenshots by "pid:title" (for background tabs)
var tabScreenshotCache: [String: NSImage] = [:]
```

### Cache Key for Tabs

Background tabs get synthetic window IDs that change between enumerations. Use a stable key:

```swift
func tabCacheKey(pid: pid_t, title: String) -> String {
    return "\(pid):\(title)"
}
```

**Important**: Don't include `tabIndex` in the key - enumeration order is unreliable.

### When to Cache

```swift
// When capturing a visible window, also cache for future background tab use
let cacheKey = tabCacheKey(pid: window.pid, title: window.title)
manager.setTabScreenshot(key: cacheKey, image: fullImage)
```

### Retrieving Cached Screenshots

For background tabs, check the tab cache first:

```swift
if window.parentWindowID != nil {  // Is background tab
    let cacheKey = tabCacheKey(pid: window.pid, title: window.title)
    if let cached = getTabScreenshot(key: cacheKey) {
        return cached  // Use cached screenshot
    }
    // Can't capture background tab - fall back to app icon
    return appIcon
}
```

## Background Tabs

Background tabs (non-frontmost tabs in Terminal, Safari, etc.) **cannot be captured** because they're not rendered. The only way to show screenshots for them:

1. **Cache when active** - When a tab is frontmost, capture and cache it
2. **Show cached version** - When it becomes a background tab, show the cached image
3. **Fall back to app icon** - If no cached screenshot exists

## OCR for Content Search

Winby supports searching by visible text using Vision framework:

```swift
import Vision

func performOCR(on image: CGImage) async -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate

    let handler = VNImageRequestHandler(cgImage: image)
    try? handler.perform([request])

    guard let observations = request.results else { return "" }

    return observations
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
}
```

### OCR Caching

Cache OCR results and only re-run when screenshot changes:

```swift
// Hash the image to detect changes
var screenshotHashes: [UInt32: Int] = [:]

func hasScreenshotChanged(windowID: UInt32, newImage: CGImage) -> Bool {
    let newHash = computeHash(newImage)
    if screenshotHashes[windowID] == newHash {
        return false  // Screenshot unchanged
    }
    screenshotHashes[windowID] = newHash
    return true
}
```

## Required Permissions

Screenshot capture requires **Screen Recording** permission:
System Settings > Privacy & Security > Screen Recording

Check and request:
```swift
// Check if granted
let hasPermission = CGPreflightScreenCaptureAccess()

// Request (shows system prompt)
let granted = CGRequestScreenCaptureAccess()
```

## Performance Tips

1. **Batch SCShareableContent calls** - One call, multiple captures
2. **Cache aggressively** - Screenshots are expensive
3. **Use private API for other-space windows** - It's the only option
4. **Capture at appropriate resolution** - Don't capture 4K for thumbnails
5. **Run captures in background tasks** - Don't block UI thread
