import SwiftUI

struct WindowRow: View {
    let window: WindowInfo
    let isSelected: Bool
    let hasContentMatch: Bool
    let thumbnail: NSImage?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Thumbnail with app icon badge
                ZStack(alignment: .bottomTrailing) {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 45)
                            .cornerRadius(4)
                            .shadow(radius: 1)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 45)
                            .cornerRadius(4)
                    }

                    // App icon badge
                    if let icon = window.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            .offset(x: 4, y: 4)
                    }
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if hasContentMatch {
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 9))
                                .foregroundColor(.blue)
                                .help("Matched in window content")
                        }
                    }
                    Text(window.appName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.leading, window.isClusteredTab ? 20 : 8)  // Indent clustered tabs
        .padding(.trailing, 8)
        .background(isSelected ? Color.accentColor.opacity(0.4) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
        )
    }
}
