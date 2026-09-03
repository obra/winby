# Changelog

All notable changes to Winby will be documented in this file.

## [Unreleased]

### Fixed
- UI freeze (spinning beachball) while the sidebar is open, caused by browser tab discovery running synchronous AppleScript on the main thread from the 1-second refresh timer. Tab lookups now run on a background queue behind a short-lived cache, and the scripts carry an explicit `with timeout` so a busy browser can no longer stall the Apple Event send.

## [1.3.1] - 2026-01-02

### Fixed
- High CPU usage when app is idle (window refresh timer now only runs when sidebar is visible)

### Added
- Release notes shown in Sparkle update dialog (parsed from CHANGELOG.md)

## [1.3.0] - 2026-01-02

### Added
- **Privacy protection for password managers**: 1Password, Bitwarden, Keychain Access, and Passwords are shown in the window list but never screenshotted or introspected
- **Comprehensive privacy documentation**: New Privacy section in README and website explaining offline operation, on-device OCR, and sensitive app handling

### Changed
- Refactored codebase into well-organized extension files for better maintainability
- Split hidden apps (completely invisible) from sensitive apps (visible but protected)

### Security
- Screenshots, thumbnails, and OCR never captured for password manager windows
- AX accessibility introspection blocked for sensitive apps
- Content indexing skips all sensitive apps entirely

## [1.2.2] - 2026-01-01

### Fixed
- Auto-updater appcast XML parsing (signature attributes were malformed)

## [1.2.1] - 2026-01-01

### Fixed
- Auto-updater public key in release builds
- No more "updater failed to start" error when running local dev builds

## [1.2.0] - 2026-01-01

### Added
- Corner resize handle on preview panel (appears on hover, maintains aspect ratio)
- Smooth 0.25s crossfade animation when switching between window previews

### Fixed
- Filter out phantom/zombie windows from "Other Spaces" section
- Preview panel now sizes exactly to screenshot (no letterboxing or empty space)

### Changed
- Preview panel has no background/border - just the screenshot with drop shadow
- Drag screenshot to move preview, drag corner handle to resize
- Moved "Cache Background Tabs" to Experiments section in settings

## [1.1.1] - 2025-01-01

### Fixed
- Search filtering now preserves original window order instead of reordering by match score
- Selection stays on current window while typing, only moves if filtered out

## [1.1.0] - 2025-01-01

### Added
- **Background tab support**: Show non-active tabs as separate entries in the window list
- **Placeholder windows**: When screenshots aren't available, show a styled placeholder with app icon and window title
- **Multi-space support**: Windows from other spaces now appear in a separate "Other Spaces" section
- **Tab screenshot caching**: Optional feature to cycle through tabs and cache their screenshots
- **Settings toggles**: New options for "Show Background Tabs" and "Cache Background Tabs"

### Fixed
- Space switching now works reliably for windows on other desktops
- Focus restoration when dismissing without selecting a window
- Tab switching for Terminal, Safari, Chrome, and other tabbed apps
- Window selection highlighting and duplicate detection
- Crash in event tap handler
- Preview window sizing now matches actual window dimensions

### Changed
- Improved preview window behavior and positioning
- Better placeholder images that match actual window dimensions

## [1.0.0] - 2024-12-29

### Added
- Initial release
- Fast window switching with Cmd+Tab
- Real-time window previews
- Fuzzy search across window titles and content
- Tab support for Terminal, Safari, Chrome
- Sparkle auto-updates
