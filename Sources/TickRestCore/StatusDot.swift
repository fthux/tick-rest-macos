import Foundation

public enum StatusDotState: String, CaseIterable {
    case working, resting, attention, deferred, inactive
    public var title: String { L10n.text("status_dot.\(rawValue)") }
}

/// Persist opaque sRGB components, independent of AppKit and SwiftUI.
public struct SRGBColor: Codable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        func component(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        self.red = component(red); self.green = component(green); self.blue = component(blue)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try values.decode(Double.self, forKey: .red),
                  green: try values.decode(Double.self, forKey: .green),
                  blue: try values.decode(Double.self, forKey: .blue))
    }
}

public typealias StatusDotColor = SRGBColor

public struct StatusDotPalette: Codable, Equatable {
    public var working = StatusDotColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    public var resting = StatusDotColor(red: 0, green: 122 / 255, blue: 1)
    public var attention = StatusDotColor(red: 1, green: 149 / 255, blue: 0)
    public var deferred = StatusDotColor(red: 175 / 255, green: 82 / 255, blue: 222 / 255)
    public var inactive = StatusDotColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    public init() {}

    public subscript(_ state: StatusDotState) -> StatusDotColor {
        get {
            switch state {
            case .working: return working
            case .resting: return resting
            case .attention: return attention
            case .deferred: return deferred
            case .inactive: return inactive
            }
        }
        set {
            switch state {
            case .working: working = newValue
            case .resting: resting = newValue
            case .attention: attention = newValue
            case .deferred: deferred = newValue
            case .inactive: inactive = newValue
            }
        }
    }
}
