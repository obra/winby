# Changelog

All notable changes to Winby will be documented in this file.

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
