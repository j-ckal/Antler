import AppKit
import SwiftUI

@main
struct AntlerApp: App {
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor)
        } label: {
            Image(nsImage: menuBarImage())
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarImage() -> NSImage {
        let topLine = monitor.menuBarTopRow
        let bottomLine = monitor.menuBarBottomRow

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]

        let topSize = (topLine as NSString).size(withAttributes: attrs)
        let bottomSize = (bottomLine as NSString).size(withAttributes: attrs)

        let width = max(topSize.width, bottomSize.width)
        let height: CGFloat = 22  // menu bar height

        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let lineHeight = font.ascender - font.descender
            let totalHeight = lineHeight * 2 + 1
            let yOffset = (rect.height - totalHeight) / 2

            (bottomLine as NSString).draw(
                at: NSPoint(
                    x: (width - bottomSize.width) / 2,
                    y: yOffset
                ),
                withAttributes: attrs
            )
            (topLine as NSString).draw(
                at: NSPoint(
                    x: (width - topSize.width) / 2,
                    y: yOffset + lineHeight + 1
                ),
                withAttributes: attrs
            )
            return true
        }
        img.isTemplate = true
        return img
    }
}
