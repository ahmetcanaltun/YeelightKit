import Foundation

/// A Yeelight device as announced over SSDP.
///
/// `support` matters more than it looks: the protocol rejects any method the
/// device did not advertise, and models differ sharply — a Monitor Light Bar
/// puts colour on its *background* light and offers none on the main one,
/// while a colour bulb has no background light at all.
public struct YeelightDevice: Sendable, Identifiable, Hashable, Codable {

    /// The device's own id from the SSDP response, falling back to the address.
    public let id: String
    public let host: String
    public let port: UInt16

    /// Name set by the user in the vendor app. Often empty.
    public var name: String?
    /// e.g. `lamp15` (Monitor Light Bar Pro), `colore` (colour bulb), `mono`.
    public var model: String?
    public var firmwareVersion: String?

    /// Methods the device accepts. Anything outside this list is rejected.
    public var support: Set<String>

    /// Last time the device answered a discovery request.
    public var lastSeen: Date

    public init(
        id: String,
        host: String,
        port: UInt16 = 55443,
        name: String? = nil,
        model: String? = nil,
        firmwareVersion: String? = nil,
        support: Set<String> = [],
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.name = name
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.support = support
        self.lastSeen = lastSeen
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return host
    }

    /// Whether the device advertised a method. An empty support set means the
    /// device was created by hand rather than discovered, so nothing is known
    /// and callers should assume the method might work.
    public func supports(_ method: YeelightMethod) -> Bool {
        support.isEmpty || support.contains(method.rawValue)
    }

    /// The device has a separately controllable background ("ambient") light.
    public var hasBackgroundLight: Bool {
        support.contains(YeelightMethod.backgroundSetPower.rawValue)
    }

    /// Which method sets an RGB colour on this device, if any. Colour-temperature
    /// only devices such as `lamp15` answer with their background light instead.
    public var colorMethod: YeelightMethod? {
        if support.isEmpty { return .setRGB }
        if support.contains(YeelightMethod.setRGB.rawValue) { return .setRGB }
        if support.contains(YeelightMethod.backgroundSetRGB.rawValue) { return .backgroundSetRGB }
        return nil
    }

    /// One of a device's two light engines.
    public enum Endpoint: Sendable, Equatable {
        case main
        case background
    }

    /// Where a colour flow should run on this device, or `nil` if it cannot run
    /// at all.
    ///
    /// A flow needs an engine that can reach every colour it asks for, and the
    /// two engines differ: a Monitor Light Bar's main light has colour
    /// temperature and no colour, while its background light has both. So a
    /// candle belongs on the main light and a rainbow has to go to the
    /// background, on the same device.
    public func endpoint(for flow: ColorFlow) -> Endpoint? {
        if flow.needsColor {
            if supports(.setRGB), supports(.startColorFlow) { return .main }
            if supports(.backgroundSetRGB), supports(.backgroundStartColorFlow) { return .background }
            return nil
        }
        if supports(.setColorTemperature), supports(.startColorFlow) { return .main }
        if supports(.backgroundSetColorTemperature), supports(.backgroundStartColorFlow) { return .background }
        return nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Working out what an unadvertised device can do

extension YeelightDevice {

    /// Methods no `get_prop` can prove or disprove, and which every documented
    /// device has. Assuming them keeps a hand-entered device exactly as capable
    /// as it is today, so inference can only ever *narrow* the guesswork.
    private static let assumedMethods: Set<YeelightMethod> = [
        .getProp, .setPower, .toggle, .setBright, .setDefault, .setName,
        .setScene, .startColorFlow, .stopColorFlow, .adjustBright,
        .cronAdd, .cronGet, .cronDelete
    ]

    /// Derives a support list from what a device answered `get_prop` with.
    ///
    /// A device only advertises its `support` list over SSDP, so one the user
    /// added by typing an IP arrives with nothing — and `supports(_:)` then has
    /// to assume everything, which is why a colour-temperature-only bar can
    /// still be shown a colour picker it will refuse.
    ///
    /// An unknown property comes back as an empty string rather than an error,
    /// which makes `get_prop` a free capability test: a device that reports no
    /// `bg_power` has no background light, and one that reports no `rgb`, `hue`
    /// or `sat` has no colour. What cannot be probed is assumed present, so the
    /// result is never *less* capable than the "assume everything" it replaces.
    ///
    /// - Returns: an inferred support list, or an empty set meaning "learned
    ///   nothing" — a device that answered no property at all is unreadable
    ///   rather than featureless, and callers must keep treating it as unknown.
    ///
    /// - Note: `set_segment_rgb` is deliberately absent. It has no readable
    ///   property (twenty-two candidate names all came back empty on hardware),
    ///   so segmented control cannot be inferred and only a discovered device
    ///   gets it. `set_music` is inferred from `music_on`, which is weaker
    ///   evidence: the property could exist on a device that does not advertise
    ///   the method.
    public static func inferredSupport(fromProperties properties: [String: String]) -> Set<String> {
        func has(_ property: YeelightProperty) -> Bool {
            guard let value = properties[property.rawValue] else { return false }
            return !value.isEmpty
        }

        // No power and no brightness means the device told us nothing usable —
        // an empty answer, a wedged light, a timeout. Inferring from that would
        // strip a working device of its controls.
        guard has(.power) || has(.mainPower) || has(.bright) else { return [] }

        var methods = assumedMethods

        if has(.colorTemperature) {
            methods.formUnion([.setColorTemperature, .adjustColorTemperature])
        }
        if has(.rgb) || has(.hue) || has(.saturation) {
            methods.formUnion([.setRGB, .setHSV, .adjustColor])
        }
        if has(.musicOn) {
            methods.insert(.setMusic)
        }

        if has(.backgroundPower) {
            methods.formUnion([.backgroundSetPower, .backgroundToggle, .backgroundSetBright,
                               .backgroundSetScene, .backgroundStartColorFlow, .backgroundStopColorFlow])
            if has(.backgroundColorTemperature) {
                methods.insert(.backgroundSetColorTemperature)
            }
            if has(.backgroundRGB) || has(.backgroundHue) || has(.backgroundSaturation) {
                methods.formUnion([.backgroundSetRGB, .backgroundSetHSV])
            }
        }

        return Set(methods.map(\.rawValue))
    }
}
