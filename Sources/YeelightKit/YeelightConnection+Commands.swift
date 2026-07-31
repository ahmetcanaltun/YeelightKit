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

    // MARK: - Segments

    /// Colours the light's addressable sections in a single command.
    ///
    /// Undocumented, and reconstructed from a device rather than from the spec —
    /// `DEVICES.md` has the evidence. What is established on the Monitor Light
    /// Bar Pro:
    ///
    /// - The array maps **positionally along the bar**, one entry per section.
    /// - The bar has **three** sections, and anything past the third is dropped
    ///   silently.
    /// - The device answers `ok` to arrays of any length, so **the reply proves
    ///   nothing**; a wrong shape fails invisibly.
    ///
    /// Because of that last point this refuses an empty array locally rather
    /// than sending something that would look successful.
    ///
    /// - Parameter colors: packed `0xRRGGBB`, first entry at one end of the light.
    public func setSegmentColors(_ colors: [Int]) async throws {
        guard !colors.isEmpty else {
            throw YeelightError.invalidArgument("a segment update needs at least one colour")
        }
        for color in colors {
            try Self.validate(color, in: 0...0xFFFFFF, name: "rgb")
        }
        try await send(.setSegmentRGB, parameters: colors.map { .int($0) })
    }

    // MARK: - Scenes

    /// Applies a whole lighting state in one command, turning the light on as
    /// part of it.
    ///
    /// Use this rather than `setPower(true)` followed by adjustments: those are
    /// separate requests, the device rejects brightness and colour while the
    /// light is still off, and nothing guarantees the power command wins the
    /// race. See ``LightScene``.
    public func setScene(_ scene: LightScene) async throws {
        try await send(.setScene, parameters: scene.validated().parameters)
    }

    public func setBackgroundScene(_ scene: LightScene) async throws {
        try await send(.backgroundSetScene, parameters: scene.validated().parameters)
    }

    // MARK: - Colour flow

    /// Hands an animation to the device to run on its own.
    ///
    /// Preferred over stepping an animation from the caller: one command instead
    /// of one per step, so the 60-per-minute quota stops being a constraint and
    /// the flow outlives the process that started it.
    public func start(_ flow: ColorFlow) async throws {
        let flow = try flow.validated()
        try await send(.startColorFlow, parameters: [
            .int(flow.changeCount), .int(flow.completion.rawValue), .string(flow.expression)
        ])
    }

    public func stopColorFlow() async throws {
        try await send(.stopColorFlow)
    }

    public func startBackgroundColorFlow(_ flow: ColorFlow) async throws {
        let flow = try flow.validated()
        try await send(.backgroundStartColorFlow, parameters: [
            .int(flow.changeCount), .int(flow.completion.rawValue), .string(flow.expression)
        ])
    }

    public func stopBackgroundColorFlow() async throws {
        try await send(.backgroundStopColorFlow)
    }

    /// Runs the flow wherever this device can show colour — the main light on a
    /// bulb, the background light on a Monitor Light Bar.
    public func startOnAvailableEndpoint(_ flow: ColorFlow) async throws {
        switch device.colorMethod {
        case .setRGB: try await start(flow)
        case .backgroundSetRGB: try await startBackgroundColorFlow(flow)
        default: throw YeelightError.unsupportedMethod(.startColorFlow)
        }
    }

    /// Stops a flow on whichever endpoint ``startOnAvailableEndpoint(_:)`` used.
    public func stopFlowOnAvailableEndpoint() async throws {
        switch device.colorMethod {
        case .setRGB: try await stopColorFlow()
        case .backgroundSetRGB: try await stopBackgroundColorFlow()
        default: throw YeelightError.unsupportedMethod(.stopColorFlow)
        }
    }

    // MARK: - Helpers

    private static func validate(_ value: Int, in range: ClosedRange<Int>, name: String) throws {
        guard range.contains(value) else {
            throw YeelightError.invalidArgument("\(name) must be \(range.lowerBound)...\(range.upperBound), got \(value)")
        }
    }
}
