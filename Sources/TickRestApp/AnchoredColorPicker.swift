import AppKit
import SwiftUI

/// Keep the system color panel, but open it beside the well that owns the edit.
struct AnchoredColorPicker: NSViewRepresentable {
    @Binding var selection: Color
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> AnchoredColorWell {
        let well = AnchoredColorWell(frame: .zero)
        well.colorWellStyle = .minimal
        well.pulldownTarget = well
        well.pulldownAction = #selector(AnchoredColorWell.showPanel)
        well.target = context.coordinator
        well.action = #selector(Coordinator.changeColor(_:))
        well.isContinuous = true
        if #available(macOS 14, *) { well.supportsAlpha = false }
        return well
    }

    func updateNSView(_ well: AnchoredColorWell, context: Context) {
        context.coordinator.selection = $selection
        let color = NSColor(selection)
        if well.color != color { well.color = color }
        well.setAccessibilityLabel(label)
        well.isEnabled = isEnabled
        if !isEnabled { well.closeOwnedPanel() }
    }

    static func dismantleNSView(_ well: AnchoredColorWell, coordinator: Coordinator) { well.closeOwnedPanel() }

    final class Coordinator: NSObject {
        var selection: Binding<Color>
        init(selection: Binding<Color>) { self.selection = selection }
        @objc func changeColor(_ well: NSColorWell) {
            guard well.isEnabled, let color = well.color.usingColorSpace(.sRGB) else { return }
            selection.wrappedValue = Color(nsColor: NSColor(srgbRed: color.redComponent,
                green: color.greenComponent, blue: color.blueComponent, alpha: 1))
        }
    }
}

final class AnchoredColorWell: NSColorWell {
    @objc func showPanel() {
        guard isEnabled else { return }
        activate(true)
    }

    override func activate(_ exclusive: Bool) {
        guard isEnabled, let window else { return }
        super.activate(exclusive)
        let panel = NSColorPanel.shared
        panel.isContinuous = true
        panel.showsAlpha = false
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? window.screen
        if let screen {
            panel.setFrameOrigin(ColorPanelPlacement.origin(anchor: anchor, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame))
        }
        panel.orderFront(nil)
    }

    func closeOwnedPanel() {
        guard isActive else { return }
        deactivate()
        NSColorPanel.shared.orderOut(nil)
    }
}

enum ColorPanelPlacement {
    static func origin(anchor: NSRect, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let gap: CGFloat = 8
        let available = visibleFrame.insetBy(dx: gap, dy: gap)
        let candidates = [
            NSPoint(x: anchor.maxX + gap, y: anchor.maxY - panelSize.height),
            NSPoint(x: anchor.minX - gap - panelSize.width, y: anchor.maxY - panelSize.height),
            NSPoint(x: anchor.maxX - panelSize.width, y: anchor.minY - gap - panelSize.height),
            NSPoint(x: anchor.maxX - panelSize.width, y: anchor.maxY + gap)
        ]
        if let origin = candidates.first(where: { available.contains(NSRect(origin: $0, size: panelSize)) }) { return origin }
        // A small display may have no fully fitting side; keep the panel within its usable edges.
        return NSPoint(
            x: max(available.minX, min(candidates[0].x, available.maxX - panelSize.width)),
            y: max(available.minY, min(candidates[0].y, available.maxY - panelSize.height))
        )
    }
}
