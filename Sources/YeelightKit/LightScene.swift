import Foundation

/// A complete lighting state, applied in one command.
///
/// This exists to solve an ordering problem that has no clean answer otherwise.
/// `set_bright`, `set_ct_abx` and `set_rgb` are **only accepted while the light
/// is on**, so setting up a scene from a dark light means sending `set_power`
/// first and hoping the adjustments arrive after it. They are separate requests
/// with no ordering guarantee, and when they lose the race the device silently
/// keeps its old brightness.
///
/// `set_scene` takes the power-on and the settings together, so there is no race
/// to lose — and it costs one command against the 60-per-minute quota instead of
/// three.
/// `Codable` because a scene is exactly what an application saves when it saves
/// a preset: the whole lighting state, in the form the device accepts it.
public enum LightScene: Sendable, Equatable, Codable {

    /// A colour at a brightness.
    case color(rgb: Int, brightness: Int)

    /// A hue and saturation at a brightness. Preferred over ``color(rgb:brightness:)``
    /// when the source values are already HSV, since it avoids a lossy conversion.
    case hsv(hue: Int, saturation: Int, brightness: Int)

    /// A colour temperature at a brightness.
    case colorTemperature(kelvin: Int, brightness: Int)

    /// Turns on at `brightness`, then switches off by itself after `minutes`.
    /// The device runs the timer, so it survives the app quitting.
    case autoDelayOff(brightness: Int, minutes: Int)

    /// Every scene carries a brightness, whatever else it sets.
    public var brightness: Int {
        switch self {
        case .color(_, let brightness),
             .hsv(_, _, let brightness),
             .colorTemperature(_, let brightness),
             .autoDelayOff(let brightness, _):
            brightness
        }
    }

    /// The colour temperature this scene sets, if it sets one.
    public var colorTemperature: Int? {
        if case .colorTemperature(let kelvin, _) = self { return kelvin }
        return nil
    }

    var parameters: [CommandValue] {
        switch self {
        case .color(let rgb, let brightness):
            [.string("color"), .int(rgb), .int(brightness)]
        case .hsv(let hue, let saturation, let brightness):
            [.string("hsv"), .int(hue), .int(saturation), .int(brightness)]
        case .colorTemperature(let kelvin, let brightness):
            [.string("ct"), .int(kelvin), .int(brightness)]
        case .autoDelayOff(let brightness, let minutes):
            [.string("auto_delay_off"), .int(brightness), .int(minutes)]
        }
    }

    /// Checked locally because the device answers an out-of-range value with a
    /// generic rejection that gives the caller nothing to act on.
    func validated() throws -> LightScene {
        switch self {
        case .color(let rgb, let brightness):
            try Self.validate(rgb, in: 0...0xFFFFFF, name: "rgb")
            try Self.validate(brightness, in: 1...100, name: "brightness")
        case .hsv(let hue, let saturation, let brightness):
            try Self.validate(hue, in: 0...359, name: "hue")
            try Self.validate(saturation, in: 0...100, name: "saturation")
            try Self.validate(brightness, in: 1...100, name: "brightness")
        case .colorTemperature(let kelvin, let brightness):
            try Self.validate(kelvin, in: 1700...6500, name: "colour temperature")
            try Self.validate(brightness, in: 1...100, name: "brightness")
        case .autoDelayOff(let brightness, let minutes):
            try Self.validate(brightness, in: 1...100, name: "brightness")
            try Self.validate(minutes, in: 1...(24 * 60), name: "minutes")
        }
        return self
    }

    private static func validate(_ value: Int, in range: ClosedRange<Int>, name: String) throws {
        guard range.contains(value) else {
            throw YeelightError.invalidArgument(
                "\(name) must be \(range.lowerBound)...\(range.upperBound), got \(value)")
        }
    }
}
