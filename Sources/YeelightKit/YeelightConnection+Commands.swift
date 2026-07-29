import Foundation

/// Typed wrappers over the raw ``YeelightConnection/send(_:parameters:)``.
///
/// Each one validates its arguments locally, because the device answers an
/// out-of-range value with a generic rejection that is hard to act on.
extension YeelightConnection {

    /// Default transition time in milliseconds.
    public static let defaultDuration = 500

    // MARK: - Main light

    public func setPower(
        _ on: Bool,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try await send(.setPower, parameters: [.string(on ? "on" : "off"), .init(effect), .int(duration)])
    }

    public func toggle() async throws {
        try await send(.toggle)
    }

    /// - Parameter brightness: 1...100. The device rejects this while off.
    public func setBrightness(
        _ brightness: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try Self.validate(brightness, in: 1...100, name: "brightness")
        try await send(.setBright, parameters: [.int(brightness), .init(effect), .int(duration)])
    }

    /// - Parameter kelvin: 1700...6500. The device rejects this while off.
    public func setColorTemperature(
        _ kelvin: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try Self.validate(kelvin, in: 1700...6500, name: "colour temperature")
        try await send(.setColorTemperature, parameters: [.int(kelvin), .init(effect), .int(duration)])
    }

    /// - Parameter rgb: packed 0xRRGGBB.
    public func setColor(
        rgb: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try Self.validate(rgb, in: 0...0xFFFFFF, name: "rgb")
        try await send(.setRGB, parameters: [.int(rgb), .init(effect), .int(duration)])
    }

    /// Sends hue and saturation directly, which avoids the precision lost by
    /// converting to RGB first.
    /// - Parameters:
    ///   - hue: 0...359
    ///   - saturation: 0...100
    public func setColor(
        hue: Int,
        saturation: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try Self.validate(hue, in: 0...359, name: "hue")
        try Self.validate(saturation, in: 0...100, name: "saturation")
        try await send(.setHSV, parameters: [.int(hue), .int(saturation), .init(effect), .int(duration)])
    }

    // MARK: - Background light

    public func setBackgroundPower(
        _ on: Bool,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try await send(.backgroundSetPower,
                       parameters: [.string(on ? "on" : "off"), .init(effect), .int(duration)])
    }

    public func setBackgroundBrightness(
        _ brightness: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try Self.validate(brightness, in: 1...100, name: "brightness")
        try await send(.backgroundSetBright, parameters: [.int(brightness), .init(effect), .int(duration)])
    }

    public func setBackgroundColor(
        rgb: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        try Self.validate(rgb, in: 0...0xFFFFFF, name: "rgb")
        try await send(.backgroundSetRGB, parameters: [.int(rgb), .init(effect), .int(duration)])
    }

    /// Sets a colour on whichever endpoint this device actually has: the main
    /// light on a bulb, the background light on a Monitor Light Bar.
    public func setColorOnAvailableEndpoint(
        rgb: Int,
        effect: YeelightEffect = .smooth,
        duration: Int = defaultDuration
    ) async throws {
        guard let method = device.colorMethod else {
            throw YeelightError.unsupportedMethod(.setRGB)
        }
        try Self.validate(rgb, in: 0...0xFFFFFF, name: "rgb")
        try await send(method, parameters: [.int(rgb), .init(effect), .int(duration)])
    }

    // MARK: - Helpers

    private static func validate(_ value: Int, in range: ClosedRange<Int>, name: String) throws {
        guard range.contains(value) else {
            throw YeelightError.invalidArgument("\(name) must be \(range.lowerBound)...\(range.upperBound), got \(value)")
        }
    }
}
