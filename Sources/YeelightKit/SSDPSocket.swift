import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A UDP socket for one SSDP search.
///
/// `NWConnection` is deliberately not used here. It binds to the peer it was
/// created with, so a connection aimed at the multicast group never delivers
/// the replies — those arrive as *unicast* from each device's own address, and
/// the framework drops them as coming from the wrong endpoint. A plain socket
/// receives from any source, which is what the SSDP exchange requires.
struct SSDPSocket {

    enum SocketError: Error {
        case cannotOpen(String)
        case cannotBind(String)
    }

    private let handle: Int32

    /// - Parameter localAddress: the interface address to send from. Multicast
    ///   follows the routing table otherwise, which picks the wrong interface
    ///   when two of them share a subnet.
    init(localAddress: String?) throws {
        handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { throw SocketError.cannotOpen(String(cString: strerror(errno))) }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        if let localAddress {
            var interface = in_addr()
            guard inet_pton(AF_INET, localAddress, &interface) == 1 else {
                Darwin.close(handle)
                throw SocketError.cannotBind("bad address \(localAddress)")
            }
            setsockopt(handle, IPPROTO_IP, IP_MULTICAST_IF,
                       &interface, socklen_t(MemoryLayout<in_addr>.size))

            var local = sockaddr_in()
            local.sin_family = sa_family_t(AF_INET)
            local.sin_addr = interface
            local.sin_port = 0 // ephemeral; replies come back here
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                Darwin.close(handle)
                throw SocketError.cannotBind(String(cString: strerror(errno)))
            }
        }

        var ttl: Int32 = 4
        setsockopt(handle, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
    }

    /// - Returns: bytes written, or -1. A successful write does not guarantee
    ///   delivery: on Apple platforms the local network privacy gate drops
    ///   multicast from an unapproved binary without reporting an error.
    @discardableResult
    func send(_ payload: Data, toHost host: String, port: UInt16) -> Int {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &destination.sin_addr)

        return payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(handle, bytes.baseAddress, payload.count, 0,
                           $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Blocks up to the socket's receive timeout. Returns nil on timeout.
    func receive() -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(handle, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        return String(bytes: buffer[0..<received], encoding: .utf8)
    }

    func close() {
        #if canImport(Darwin)
        Darwin.close(handle)
        #else
        Glibc.close(handle)
        #endif
    }
}
