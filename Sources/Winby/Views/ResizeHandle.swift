import SwiftUI

struct ResizeHandle: View {
    @Binding var isResizing: Bool
    let aspectRatio: CGFloat
    @State private var dragStartLocation: NSPoint = .zero
    @State private var initialFrame: NSRect = .zero

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.8))
            .padding(6)
            .background(Circle().fill(Color.black.opacity(0.4)))
            .padding(8)
            .contentShape(Rectangle().size(width: 44, height: 44))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard let window = (NSApp.delegate as? AppDelegate)?.previewWindow else { return }

                        if !isResizing {
                            isResizing = true
                            dragStartLocation = NSEvent.mouseLocation
                            initialFrame = window.frame
                        }

                        // Calculate delta from drag start using screen coordinates
                        let currentMouse = NSEvent.mouseLocation
                        let deltaX = currentMouse.x - dragStartLocation.x
                        let deltaY = currentMouse.y - dragStartLocation.y

                        // Use the larger delta to drive resize, maintain aspect ratio
                        let widthFromDeltaX = initialFrame.width + deltaX
                        let widthFromDeltaY = (initialFrame.height - deltaY) * aspectRatio

                        // Pick the dimension that gives larger size
                        var newWidth = max(widthFromDeltaX, widthFromDeltaY)
                        newWidth = max(200, newWidth)
                        let newHeight = newWidth / aspectRatio

                        // Keep top-left corner fixed
                        let topY = initialFrame.origin.y + initialFrame.height
                        let newY = topY - newHeight

                        window.setFrame(
                            NSRect(x: initialFrame.origin.x, y: newY, width: newWidth, height: newHeight),
                            display: true
                        )
                    }
                    .onEnded { _ in
                        isResizing = false
                    }
            )
            .opacity(isResizing ? 1 : 0.7)
            .onHover { hovering in
                if hovering {
                    NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!, hotSpot: NSPoint(x: 8, y: 8)).push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
