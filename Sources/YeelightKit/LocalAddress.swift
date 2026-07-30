import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Works out which of our own addresses a given device can reach us on.
///
/// Music mode inverts the connection — the device dials back to an address we
/// hand it — so guessing wrong means it simply never arrives. A machine with
/// Wi-Fi and Ethernet on the same subnet makes "the local IP" ambiguous, so
/// instead of choosing, ask the kernel: connecting a UDP socket sends nothing
/// but does make it pick the source address the routing table would use.
enum LocalAddress {

    static func forReaching(host: String, port: UInt16 = 55443) -> String? {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return nil }
        defer { close(handle) }

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return nil }

        let connected = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else { return nil }

        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(text.count)) != nil else {
            return nil
        }
        return String(cString: text)
    }
}
