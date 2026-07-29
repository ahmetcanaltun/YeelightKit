import Foundation

/// A snapshot of a device's light state.
///
/// Every field is optional because devices only report what they have: a
/// colour-temperature-only bar never sends `rgb`, and a bulb without a
/// background light never sends any `background*` value. `nil` means "this
/// device did not tell us", not "zero".
public struct YeelightState: Sendable, Equatable {

    public enum ColorMode: Int, Sendable {
        case rgb = 1
        case colorTemperature = 2
        case hsv = 3
    }

    // Main light
    public var isOn: Bool?
    /// 1...100
    public var brightness: Int?
    /// Kelvin, typically 1700...6500
    public var colorTemperature: Int?
    /// Packed 0xRRGGBB
    public var rgb: Int?
    /// 0...359
    public var hue: Int?
    /// 0...100
    public var saturation: Int?
    public var colorMode: ColorMode?

    // Background ("ambient") light
    public var backgroundIsOn: Bool?
    public var backgroundBrightness: Int?
    public var backgroundColorTemperature: Int?
    public var backgroundRGB: Int?
    public var backgroundColorMode: ColorMode?

    public init() {}

    /// Builds a state from a `get_prop` answer or a `props` notification.
    ///
    /// Values are keyed by their protocol names. An empty string means the
    /// device does not know the property and is skipped rather than parsed
    /// as a real value.
    public init(properties: [String: String]) {
        func text(_ property: YeelightProperty) -> String? {
            guard let value = properties[property.rawValue], !value.isEmpty else { return nil }
            return value
        }
        func number(_ property: YeelightProperty) -> Int? { text(property).flatMap(Int.init) }

        // On devices with a background light, `power` describes the device as a
        // whole and is "on" whenever the ambient light is lit, while
        // `main_power` describes the main light. Notifications carry only the
        // latter, so it has to win where both are present.
        if let power = text(.mainPower) ?? text(.power) { isOn = (power == "on") }
        brightness = number(.bright)
        colorTemperature = number(.colorTemperature)
        rgb = number(.rgb)
        hue = number(.hue)
        saturation = number(.saturation)
        colorMode = number(.colorMode).flatMap(ColorMode.init(rawValue:))

        if let power = text(.backgroundPower) { backgroundIsOn = (power == "on") }
        backgroundBrightness = number(.backgroundBright)
        backgroundColorTemperature = number(.backgroundColorTemperature)
        backgroundRGB = number(.backgroundRGB)
        backgroundColorMode = number(.backgroundColorMode).flatMap(ColorMode.init(rawValue:))
    }

    /// Overlays any values the other state actually carries, leaving the rest
    /// untouched. Notifications are partial, so they are merged rather than
    /// replacing what is already known.
    public func merging(_ update: YeelightState) -> YeelightState {
        var result = self
        if let v = update.isOn { result.isOn = v }
        if let v = update.brightness { result.brightness = v }
        if let v = update.colorTemperature { result.colorTemperature = v }
        if let v = update.rgb { result.rgb = v }
        if let v = update.hue { result.hue = v }
        if let v = update.saturation { result.saturation = v }
        if let v = update.colorMode { result.colorMode = v }
        if let v = update.backgroundIsOn { result.backgroundIsOn = v }
        if let v = update.backgroundBrightness { result.backgroundBrightness = v }
        if let v = update.backgroundColorTemperature { result.backgroundColorTemperature = v }
        if let v = update.backgroundRGB { result.backgroundRGB = v }
        if let v = update.backgroundColorMode { result.backgroundColorMode = v }
        return result
    }
}
