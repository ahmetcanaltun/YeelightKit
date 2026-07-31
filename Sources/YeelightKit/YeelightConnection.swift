import Foundation
import Network

/// A control connection to one Yeelight device.
///
/// An actor rather than a class: the protocol requires correlating replies to
/// in-flight requests by id, and actor isolation gives that for free instead of
/// the lock-and-serial-queue arrangement a shared class would need.
///
/// ## Limits the protocol imposes
///
/// - A device accepts **at most 4 simultaneous TCP connections** and silently
///   refuses to answer beyond that. Always ``close()`` a connection you are
///   done with; an abandoned one keeps its slot until the device is power
///   cycled, which looks exactly like a broken light.
/// - Each connection has a quota of **60 commands per minute**. Anything that
///   animates must pace itself; see ``minimumCommandInterval``.
/// - `set_bright`, `set_ct_abx` and `set_rgb` are only accepted **while the
///   light is on**.
public actor YeelightConnection {

    /// Where the connection actually is.
    ///
    /// Recovery happens inside this actor, so without publishing it a caller
    /// cannot tell a live connection from one that dropped and is backing off —
    /// and every command in between fails with ``YeelightError/notConnected``
    /// for no visible reason.
    public enum Link: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        /// Dropped unexpectedly and retrying. `attempt` counts from 1.
        case reconnecting(attempt: Int, of: Int)
        /// Gave up. Only an explicit ``connect()`` will try again.
        case failed(String)
    }

    /// Slowest safe cadence for repeated commands: 60 per minute per connection.
    public static let minimumCommandInterval: Duration = .seconds(1)

    /// Mutable only so ``learnCapabilities()`` can fill in a support list the
    /// device never advertised. Nothing else changes it.
    public private(set) var device: YeelightDevice

    private var connection: NWConnection?
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String], Error>] = [:]
    private var buffer = Data()

    private var stateContinuations: [UUID: AsyncStream<YeelightState>.Continuation] = [:]
    private var lastState = YeelightState()

    private var linkContinuations: [UUID: AsyncStream<Link>.Continuation] = [:]
    private var link: Link = .disconnected {
        didSet {
            guard link != oldValue else { return }
            for continuation in linkContinuations.values { continuation.yield(link) }
        }
    }

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// False once `close()` has been called, so the teardown that follows is not
    /// mistaken for a drop worth recovering from.
    private var wantsConnection = false

    /// How long to wait for a reply before giving up.
    public var timeout: Duration = .seconds(5)

    /// Attempts to reconnect on its own after an unexpected drop, backing off
    /// between tries. Set to 0 to never reconnect. An explicit ``close()``
    /// always wins — it is treated as intent, not as a failure.
    public var maximumReconnectAttempts = 5

    public init(device: YeelightDevice) {
        self.device = device
    }

    deinit {
        // An NWConnection lives until cancelled; dropping the reference alone
        // would leak one of the device's four slots.
        reconnectTask?.cancel()
        connection?.cancel()
    }

    // MARK: - Lifecycle

    public var isConnected: Bool {
        connection?.state == .ready
    }

    public func connect() async throws {
        if connection?.state == .ready { return }
        close()
        wantsConnection = true
        link = .connecting

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.noDelay = true
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(integerLiteral: device.port),
            using: parameters
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLockBox(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.testAndSet() { continuation.resume() }
                case .failed(let error):
                    if resumed.testAndSet() {
                        continuation.resume(throwing: YeelightError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if resumed.testAndSet() {
                        continuation.resume(throwing: YeelightError.notConnected)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        reconnectAttempt = 0
        link = .connected
        receiveLoop(on: connection)
    }

    /// Cancels the connection and releases the device slot it holds.
    ///
    /// Also cancels any pending reconnection: closing is an instruction, not a
    /// failure to recover from.
    public func close() {
        wantsConnection = false
        link = .disconnected
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        for continuation in pending.values {
            continuation.resume(throwing: YeelightError.notConnected)
        }
        pending.removeAll()
        buffer.removeAll()
    }

    // MARK: - State

    /// Emits a merged snapshot every time the device reports a change.
    ///
    /// Notifications are partial, so each element is the full known state
    /// rather than only what changed.
    public func states() -> AsyncStream<YeelightState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(lastState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    /// Emits every time the connection's own state changes, starting with where
    /// it is now.
    public func links() -> AsyncStream<Link> {
        AsyncStream { continuation in
            let id = UUID()
            linkContinuations[id] = continuation
            continuation.yield(link)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeLinkContinuation(id) }
            }
        }
    }

    private func removeLinkContinuation(_ id: UUID) {
        linkContinuations[id] = nil
    }

    private func publish(_ update: YeelightState) {
        lastState = lastState.merging(update)
        for continuation in stateContinuations.values {
            continuation.yield(lastState)
        }
    }

    /// Reads the device's current state. Unsupported properties come back empty
    /// and are simply left `nil`.
    @discardableResult
    public func refreshState() async throws -> YeelightState {
        publish(YeelightState(properties: try await readProperties()))
        return lastState
    }

    /// One `get_prop` for everything the library knows how to read, keyed by
    /// property name. Values are kept verbatim, empty ones included: an empty
    /// answer is the device saying it does not have that property, which is
    /// information in itself.
    private func readProperties() async throws -> [String: String] {
        let names = YeelightProperty.allCases.map(\.rawValue)
        let values = try await send(.getProp, parameters: names.map { .string($0) })

        var properties: [String: String] = [:]
        for (name, value) in zip(names, values) {
            properties[name] = value
        }
        return properties
    }

    /// Works out what a hand-entered device can do, by asking it.
    ///
    /// Only devices found over SSDP carry a `support` list; one the user typed
    /// an IP for arrives with nothing, and every capability check then has to
    /// assume the best. This reads the properties the device actually answers
    /// and derives a list from them — see
    /// ``YeelightDevice/inferredSupport(fromProperties:)`` for what can and
    /// cannot be established that way.
    ///
    /// Does nothing for a device that already advertised its own list: a real
    /// advertisement always beats a guess. The state read on the way is
    /// published like any other, so calling this instead of ``refreshState()``
    /// costs nothing extra.
    ///
    /// - Returns: the support list now in force, empty if nothing was learned.
    @discardableResult
    public func learnCapabilities() async throws -> Set<String> {
        guard device.support.isEmpty else { return device.support }

        let properties = try await readProperties()
        publish(YeelightState(properties: properties))

        let inferred = YeelightDevice.inferredSupport(fromProperties: properties)
        guard !inferred.isEmpty else { return [] }
        device.support = inferred
        return inferred
    }

    // MARK: - Sending

    /// Sends a raw command and waits for the matching reply.
    ///
    /// Throws ``YeelightError/unsupportedMethod(_:)`` without touching the
    /// network when the device never advertised the method.
    /// - Returns: the strings of the device's `result` array, e.g. `["ok"]`.
    @discardableResult
    public func send(_ method: YeelightMethod, parameters: [CommandValue] = []) async throws -> [String] {
        guard device.supports(method) else {
            throw YeelightError.unsupportedMethod(method)
        }
        guard let connection, connection.state == .ready else {
            throw YeelightError.notConnected
        }

        nextRequestID += 1
        let id = nextRequestID

        let payload: [String: Any] = ["id": id,
                                      "method": method.rawValue,
                                      "params": parameters.map(\.jsonValue)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              let line = (text + "\r\n").data(using: .utf8) else {
            throw YeelightError.encodingFailed
        }

        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw YeelightError.timeout
            }
            group.addTask {
                try await self.awaitReply(id: id, sending: line, on: connection)
            }
            defer {
                group.cancelAll()
                // Release the request whatever happened. On the timeout path this
                // is what lets the group finish; on the success path the reply
                // already removed it and this does nothing. Removing without
                // resuming would leak the continuation instead.
                fail(id: id, with: .timeout)
            }
            guard let result = try await group.next() else { throw YeelightError.timeout }
            return result
        }
    }

    /// Waits for the reply to `id`, and **gives up when cancelled**.
    ///
    /// The cancellation handling is not a nicety. A continuation is not
    /// cancellation-aware by itself, and a task group waits for every child
    /// before it rethrows — so without this, a command that times out leaves this
    /// task parked forever and ``send(_:parameters:)`` never returns at all,
    /// which is strictly worse than the timeout it was supposed to report.
    private func awaitReply(id: Int, sending payload: Data, on connection: NWConnection) async throws -> [String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                // Cancellation can land before the body runs, in which case the
                // handler below has nothing to find yet.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task { await self?.fail(id: id, with: .connectionFailed(error.localizedDescription)) }
                })
            }
        } onCancel: {
            Task { [weak self] in await self?.fail(id: id, with: .timeout) }
        }
    }

    private func fail(id: Int, with error: YeelightError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: - Receiving

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                Task { await self.handleDisconnect(reason: error.localizedDescription) }
                return
            }
            if let data, !data.isEmpty {
                Task { await self.ingest(data) }
            }
            if isComplete {
                Task { await self.handleDisconnect(reason: "closed by device") }
            } else {
                self.receiveLoop(on: connection)
            }
        }
    }

    private func handleDisconnect(reason: String) {
        for continuation in pending.values {
            continuation.resume(throwing: YeelightError.connectionFailed(reason))
        }
        pending.removeAll()
        scheduleReconnect(reason: reason)
    }

    /// Reconnects with a linear backoff. Only one attempt is ever in flight.
    private func scheduleReconnect(reason: String) {
        guard wantsConnection, maximumReconnectAttempts > 0 else {
            link = .disconnected
            return
        }
        guard reconnectAttempt < maximumReconnectAttempts else {
            // Out of attempts. Saying so matters: nothing will retry on its own
            // from here, and a caller left believing it is connected will keep
            // issuing commands that quietly fail.
            link = .failed(reason)
            return
        }
        guard reconnectTask == nil else { return }

        reconnectAttempt += 1
        link = .reconnecting(attempt: reconnectAttempt, of: maximumReconnectAttempts)
        let delay = Duration.seconds(2 * reconnectAttempt)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.finishReconnect()
        }
    }

    private func finishReconnect() async {
        reconnectTask = nil
        guard wantsConnection, connection?.state != .ready else { return }

        do {
            try await connect()
        } catch {
            // A failure here does *not* land back in `handleDisconnect`: a
            // connect that never reaches `.ready` never arms the receive loop,
            // so without this the backoff stops silently after a single try.
            scheduleReconnect(reason: error.localizedDescription)
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)

        // Messages are newline terminated but may arrive coalesced or split.
        while let range = buffer.range(of: Data("\r\n".utf8)) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !line.isEmpty else { continue }
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: YeelightError.deviceRejected(
                    code: error["code"] as? Int ?? -1,
                    message: error["message"] as? String ?? "unknown"
                ))
            } else {
                // Results are always an array of scalars; normalise to strings so
                // nothing untyped escapes the actor.
                let values = (message["result"] as? [Any] ?? []).map { value -> String in
                    if let text = value as? String { return text }
                    if let number = value as? NSNumber { return number.stringValue }
                    return ""
                }
                continuation.resume(returning: values)
            }
            return
        }

        // Unsolicited state change.
        if message["method"] as? String == "props",
           let params = message["params"] as? [String: Any] {
            var properties: [String: String] = [:]
            for (key, value) in params {
                properties[key] = String(describing: value)
            }
            publish(YeelightState(properties: properties))
        }
    }
}

/// Minimal lock used only to make a connection continuation resume once.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()

    init(_ value: Bool) { self.value = value }

    /// Returns true exactly once.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
