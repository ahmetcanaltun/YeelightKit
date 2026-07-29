import Foundation
import Network

/// Finds Yeelight devices on the local network over SSDP.
///
/// The search is multicast to `239.255.255.250:1982`. On a machine with more
/// than one interface on the same subnet — a Mac docked over Ethernet while
/// also on Wi-Fi is the common case — a single send leaves through whichever
/// interface the routing table prefers, which is frequently not the one the
/// lights answer on. The search is therefore repeated on every wired and Wi-Fi
/// interface.
///
/// On Apple platforms the host app must declare local network usage
/// (`NSLocalNetworkUsageDescription`) or the system blocks the multicast
/// silently.
public struct YeelightDiscovery: Sendable {

    public init() {}

    private static let multicastHost = "239.255.255.250"
    private static let multicastPort: UInt16 = 1982

    private static let searchRequest = Data("""
    M-SEARCH * HTTP/1.1\r
    HOST: 239.255.255.250:1982\r
    MAN: "ssdp:discover"\r
    ST: wifi_bulb\r\n
    """.utf8)

    /// Emits each distinct device as it answers, finishing after `duration`.
    ///
    /// A device that answers on several interfaces is emitted once.
    public func devices(for duration: Duration = .seconds(3)) -> AsyncStream<YeelightDevice> {
        AsyncStream { continuation in
            let task = Task {
                let seen = SeenDevices()
                await withTaskGroup(of: Void.self) { group in
                    for address in await Self.localAddresses() {
                        group.addTask {
                            await Self.search(on: address, for: duration) { device in
                                if await seen.insert(device.id) {
                                    continuation.yield(device)
                                }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects everything that answers within `duration`.
    public func scan(for duration: Duration = .seconds(3)) async -> [YeelightDevice] {
        var found: [YeelightDevice] = []
        for await device in devices(for: duration) {
            found.append(device)
        }
        return found
    }

    // MARK: - Internals

    /// IPv4 addresses of the wired and Wi-Fi interfaces, so the search can be
    /// repeated per interface.
    ///
    /// A Mac docked over Ethernet while also on Wi-Fi has two interfaces on one
    /// subnet; multicast then follows the routing table and leaves through only
    /// one of them, which is frequently not the one the lights answer on.
    /// An empty result means "let the system choose".
    static func localAddresses() async -> [String?] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [nil] }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_MULTICAST != 0,
                  let raw = pointer.pointee.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(raw, socklen_t(raw.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let address = String(cString: host)
            if !address.isEmpty, !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses.isEmpty ? [nil] : addresses
    }

    private static func search(
        on address: String?,
        for duration: Duration,
        onDevice: @escaping @Sendable (YeelightDevice) async -> Void
    ) async {
        guard let socket = try? SSDPSocket(localAddress: address) else { return }
        defer { socket.close() }

        socket.send(searchRequest, toHost: multicastHost, port: multicastPort)

        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let response = socket.receive() else { continue }
            if let device = parse(response: response) {
                await onDevice(device)
            }
        }
    }

    /// Parses a search response or an `ssdp:alive` advertisement.
    static func parse(response: String) -> YeelightDevice? {
        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Location looks like yeelight://192.168.1.100:55443
        guard let location = headers["location"] else { return nil }
        let address = location.replacingOccurrences(of: "yeelight://", with: "")
        let parts = address.split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 55443 : 55443

        return YeelightDevice(
            id: headers["id"] ?? host,
            host: host,
            port: port,
            name: headers["name"],
            model: headers["model"],
            firmwareVersion: headers["fw_ver"],
            support: Set(headers["support"]?.split(separator: " ").map(String.init) ?? [])
        )
    }
}

/// Deduplicates devices answering on more than one interface.
private actor SeenDevices {
    private var ids: Set<String> = []

    /// Returns true the first time an id is seen.
    func insert(_ id: String) -> Bool {
        ids.insert(id).inserted
    }
}

