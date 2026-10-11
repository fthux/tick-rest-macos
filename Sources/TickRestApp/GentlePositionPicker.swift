import SwiftUI
import AppKit
import TickRestCore

/// A small screen diagram keeps nine spatial choices compact in the settings form.
struct GentlePositionPicker: View {
    @Binding var selection: GentleReminderPosition
    @State private var hoveredPosition: GentleReminderPosition?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3) { row in
                HStack(spacing: 4) {
                    ForEach(Array(GentleReminderPosition.allCases[(row * 3)..<(row * 3 + 3)]), id: \.self) { position in
                        positionButton(position)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .fixedSize()
    }

    private func positionButton(_ position: GentleReminderPosition) -> some View {
        let selected = selection == position
        let hovered = hoveredPosition == position
        return Button { selection = position } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(selected ? Color.orange : Color.primary.opacity(hovered ? 0.10 : 0))
                    .frame(width: 18, height: 10)
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 8, height: 2)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(hovered ? 0.8 : 0.45))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: 26, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(position.title)
        .accessibilityLabel(position.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering in
            if hovering { hoveredPosition = position }
            else if hoveredPosition == position { hoveredPosition = nil }
        }
    }
}
