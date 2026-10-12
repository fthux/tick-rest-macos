import AppKit
import SwiftUI

/// Send changes during AppKit's tracking loop, including while the mouse is
/// down. Persistence is debounced separately from these immediate UI updates.
struct ContinuousBackgroundSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(value: $value, range: range, step: step) }
    func makeNSView(context: Context) -> BackgroundTrackingSlider {
        let slider = BackgroundTrackingSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                                               target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.sliderType = .linear
        slider.isContinuous = true
        return slider
    }
    func updateNSView(_ slider: BackgroundTrackingSlider, context: Context) {
        context.coordinator.value = $value
        context.coordinator.range = range; context.coordinator.step = step
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        // Quantized SwiftUI updates must not reset AppKit's active tracking.
        if !slider.isTrackingMouse, slider.doubleValue != value { slider.doubleValue = value }
        slider.isEnabled = isEnabled
        slider.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject {
        var value: Binding<Double>
        var range: ClosedRange<Double>
        var step: Double
        init(value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
            self.value = value; self.range = range; self.step = step
        }
        @objc func changed(_ slider: NSSlider) {
            receive(slider.doubleValue, enabled: slider.isEnabled)
        }
        func receive(_ sample: Double, enabled: Bool = true) {
            guard enabled else { return }
            value.wrappedValue = SliderValue.quantized(sample, range: range, step: step)
        }
    }
}

final class BackgroundTrackingSlider: NSSlider {
    private(set) var isTrackingMouse = false
    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        defer { isTrackingMouse = false }
        super.mouseDown(with: event)
    }
}

enum SliderValue {
    static func quantized(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        guard step.isFinite, step > 0 else { return clamped }
        return min(range.upperBound, max(range.lowerBound,
            range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step))
    }
}
