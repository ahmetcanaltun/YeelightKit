import Foundation
import Network

/// A quota-free UDP channel, for lights that stream but have no music mode.
///
/// This is not in the Inter-Operation Spec. It was reconstructed from Yeelight's
/// own Chroma Connector — `CUdpLight.cpp`, BSD licensed — and `DEVICES.md`
/// records the evidence.
///
/// It matters because the two capabilities are disjoint in practice: the devices
/// with an addressable backlight, such as the Monitor Light Bar Pro, are exactly
/// the ones that do **not** advertise `set_music`. Without this channel their
/// segment updates go over the ordinary connection and are capped at 60 commands
/// a minute, which looks like a slideshow.
///
/// Unlike ``YeelightMusicSession`` the device never dials back: we send to its
/// UDP port, it answers with a token, and every later message carries that token
/// as a **top-level field** beside `id`, `method` and `params`.
///
/// Commands are fire-and-forget. Waiting for a reply per frame would defeat the
/// point, so failures surface as the session ending rather than as a throw per
/// command.
public actor YeelightUDPSession {

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case active
        case ended(String)
    }

    /// The two generations of this protocol. A device advertises one or the
    /// other; the message shapes are identical and only the names differ.
    private enum Generation {
        case v1, v2

        var open: String { self == .v2 ? "udp_sess_new" : "udp_new" }
        var keepAlive: String { self == .v2 ? "udp_sess_keep_alive" : "udp_keep_alive" }
        var token: String { self == .v2 ? "udp_sess_token" : "udp_token" }
    }

    /// Beside the 55443 control port.
    public static let port: UInt16 = 55444

    /// The reference implementation asks for ten seconds and gives up after four
    /// unanswered.
    public static let keepAliveInterval = Duration.seconds(10)
    private static let maximumMissedKeepAlives = 4

    public private(set) var state: State = .idle

    private let device: YeelightDevice
    private let generation: Generation

    private var connection: NWConnection?
    private var token: String?
    private var nextRequestID = 0
    private var keepAliveTask: Task<Void, Never>?
    private var missedKeepAlives = 0
    private var waitingForToken: CheckedContinuation<String, Error>?

    /// Whether this device takes part in the UDP channel at all.
    ///
    /// Yeelight's own client gates on the substring `chroma` being present and
    /// then opens the session with `udp_sess_new`. So `udp_chroma_sess_new` is a
    /// **marker, not a method** — nothing ever sends it.
    public static func isSupported(_ device: YeelightDevice) -> Bool {
        generation(for: device) != nil
    }

    private static func generation(for device: YeelightDevice) -> Generation? {
        guard device.support.contains(where: { $0.contains("chroma") }) else { return nil }
        if device.support.contains("udp_sess_new") { return .v2 }
        if device.support.contains("udp_new") { return .v1 }
        return nil
    }

    public init?(device: YeelightDevice) {
        guard let generation = Self.generation(for: device) else { return nil }
        self.device = device
        self.generation = generation
    }

    deinit {
        keepAliveTask?.cancel()
        connection?.cancel()
    }

    public var isActive: Bool { state == .active }

    // MARK: - Lifecycle

    /// Opens the socket and acquires a token.
    ///
    /// - Parameter timeout: how long to wait for the device to answer.
    public func start(timeout: Duration = .seconds(5)) async throws {
        stop()
        state = .connecting

        let connection = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(integerLiteral: Self.port),
            using: .udp
        )
        self.connection = connection
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection)

        do {
            let token = try await acquireToken(timeout: timeout)
            self.token = token
            missedKeepAlives = 0
            state = .active
            startKeepAlive()
        } catch {
            stop()
            state = .ended(error.localizedDescription)
            throw error
        }
    }

    public func stop() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        connection?.cancel()
        connection = nil
        token = nil
        waitingForToken?.resume(throwing: YeelightError.notConnected)
        waitingForToken = nil
        if state != .idle { state = .idle }
    }

    // MARK: - Sending

    /// Writes a command without waiting for a reply.
    public func send(_ method: YeelightMethod, parameters: [CommandValue] = []) throws {
        guard state == .active, let connection, let token else {
            throw YeelightError.notConnected
        }
        guard device.supports(method) else {
            throw YeelightError.unsupportedMethod(method)
        }
        try write(method.rawValue, parameters.map(\.jsonValue), token: token, on: connection)
    }

    /// Colours the light's addressable sections. See
    /// ``YeelightConnection/setSegmentColors(_:)`` for what is known about it.
    public func setSegmentColors(_ colors: [Int]) throws {
        guard !colors.isEmpty else {
            throw YeelightError.invalidArgument("a segment update needs at least one colour")
        }
        try send(.setSegmentRGB, parameters: colors.map { .int($0) })
    }

    /// Pushes one colour at whatever rate the caller likes.
    ///
    /// `sudden` with a zero duration: a transition would smear consecutive
    /// frames into each other. This mirrors what the reference client sends.
    public func setColor(rgb: Int) throws {
        guard let method = device.colorMethod else {
            throw YeelightError.unsupportedMethod(.setRGB)
        }
        try send(method, parameters: [.int(rgb), .string(YeelightEffect.sudden.rawValue), .int(0)])
    }

    // MARK: - Internals

    /// Builds the message and writes it.
    ///
    /// The token sits **beside** `params` rather than inside it. Getting that
    /// wrong produces no error — the device simply ignores the command — so it
    /// is worth being explicit about.
    private func write(_ method: String, _ params: [Any], token: String?, on connection: NWConnection) throws {
        nextRequestID += 1
        var payload: [String: Any] = ["id": nextRequestID, "method": method, "params": params]
        if let token { payload["token"] = token }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              let line = (text + "\r\n").data(using: .utf8) else {
            throw YeelightError.encodingFailed
        }

        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.end(reason: error.localizedDescription) }
        })
    }

    private func acquireToken(timeout: Duration) async throws -> String {
        guard let connection else { throw YeelightError.notConnected }
        try write(generation.open, [], token: nil, on: connection)

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw YeelightError.timeout
            }
            group.addTask {
                // Cancellation has to reach this one: a task group waits for
                // every child before it rethrows, so a continuation that only
                // resumes from the receive loop would hang the group whenever
                // the timeout wins.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        Task { await self.waitForToken(continuation) }
                    }
                } onCancel: {
                    Task { await self.failTokenWait() }
                }
            }
            defer { group.cancelAll() }
            guard let token = try await group.next() else { throw YeelightError.timeout }
            return token
        }
    }

    private func waitForToken(_ continuation: CheckedContinuation<String, Error>) {
        if let token {
            continuation.resume(returning: token)
        } else {
            waitingForToken = continuation
        }
    }

    private func failTokenWait() {
        waitingForToken?.resume(throwing: YeelightError.timeout)
        waitingForToken = nil
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled else { return }
                await self?.sendKeepAlive()
            }
        }
    }

    private func sendKeepAlive() {
        guard state == .active, let connection, let token else { return }

        missedKeepAlives += 1
        if missedKeepAlives > Self.maximumMissedKeepAlives {
            end(reason: "the device stopped answering keep-alives")
            return
        }
        // The interval is a string in the reference client, and the device is
        // fussy about types elsewhere, so it is sent as one.
        try? write(generation.keepAlive,
                   ["keeplive_interval", "10"],
                   token: token,
                   on: connection)
    }

    private nonisolated func receive(on connection: NWConnection) {
        // `isComplete` is deliberately ignored. On a datagram connection it is
        // true for *every* message — it marks the end of that datagram, not the
        // end of the channel. Treating it as a close tore the session down the
        // instant the token arrived, leaving a live-looking session with no
        // socket behind it.
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { await self.ingest(data) }
            }
            if let error {
                Task { await self.end(reason: error.localizedDescription) }
                return
            }
            self.receive(on: connection)
        }
    }

    private func ingest(_ data: Data) {
        // Datagrams arrive whole, but the device terminates them anyway and may
        // coalesce two, so both shapes are handled.
        for chunk in data.split(separator: UInt8(ascii: "\n")) {
            let line = Data(chunk).drop(while: { $0 == UInt8(ascii: "\r") })
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        // The device only ever speaks in reply to us, so anything arriving at
        // all proves the session is alive. Resetting here rather than on a
        // recognised shape is deliberate: the first version insisted on finding
        // the token in a particular place, never found it, and killed a
        // perfectly healthy session on the fifth keep-alive.
        missedKeepAlives = 0

        // Two shapes, both observed on hardware:
        //   opening   {"id":1,"method":"udp_sess_token","params":{"token":"…"}}
        //   keepalive {"id":42,"result":["ok"],"token":"…"}
        // so the token is top level in one and nested in the other.
        let value = message["token"] as? String
            ?? (message["params"] as? [String: Any])?["token"] as? String

        guard let value, token == nil || message["method"] as? String == generation.token else { return }
        token = value
        waitingForToken?.resume(returning: value)
        waitingForToken = nil
    }

    private func end(reason: String) {
        guard state == .active || state == .connecting else { return }
        stop()
        state = .ended(reason)
    }
}
