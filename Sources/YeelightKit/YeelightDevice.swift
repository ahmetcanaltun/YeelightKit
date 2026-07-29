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

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
