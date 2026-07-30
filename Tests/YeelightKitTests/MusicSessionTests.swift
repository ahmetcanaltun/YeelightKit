import XCTest
@testable import YeelightKit

final class MusicSessionTests: XCTestCase {

    /// Light bar: no `set_music` at all, colour only on the background light.
    private let lightBar = YeelightDevice(
        id: "bar", host: "127.0.0.1",
        support: ["get_prop", "set_power", "set_ct_abx", "set_bright",
                  "bg_set_power", "bg_set_rgb", "bg_set_bright"]
    )

    /// Colour bulb: the only one of the two that advertises music mode.
    private let bulb = YeelightDevice(
        id: "bulb", host: "127.0.0.1",
        support: ["get_prop", "set_power", "set_bright", "set_rgb", "set_music"]
    )

    func testStartIsRejectedWhenTheDeviceHasNoMusicMode() async {
        let session = YeelightMusicSession(device: lightBar,
                                           control: YeelightConnection(device: lightBar))
        do {
            try await session.start()
            XCTFail("expected rejection")
        } catch YeelightError.unsupportedMethod(let method) {
            XCTAssertEqual(method, .setMusic)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A handshake that never lands must not leave the listener holding a port
    /// or the session claiming to be waiting.
    ///
    /// The specific error matters: reaching `notConnected` proves the listener
    /// bound and the attempt got as far as the control channel. `NWListener`
    /// fails with EINVAL if it is started before its connection handler is
    /// installed, and that once made music mode impossible on every device
    /// while looking like an unrelated "invalid argument".
    func testFailedHandshakeLeavesTheSessionIdle() async {
        let session = YeelightMusicSession(device: bulb,
                                           control: YeelightConnection(device: bulb))
        do {
            try await session.start(timeout: .milliseconds(200))
            XCTFail("expected the handshake to fail on a closed control connection")
        } catch YeelightError.notConnected {
            // Listener came up; the control connection was never opened, so
            // `set_music` could not go out.
        } catch YeelightError.connectionFailed(let reason) {
            XCTFail("the listener itself failed to start: \(reason)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSendingBeforeTheDeviceDialsInFails() async {
        let session = YeelightMusicSession(device: bulb,
                                           control: YeelightConnection(device: bulb))
        do {
            try await session.send(.setRGB, parameters: [.int(0xFF0000)])
            XCTFail("expected rejection")
        } catch YeelightError.notConnected {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testColorIsRejectedWhenTheDeviceHasNoColorEndpoint() async {
        let mono = YeelightDevice(id: "mono", host: "127.0.0.1",
                                  support: ["set_power", "set_bright", "set_music"])
        let session = YeelightMusicSession(device: mono, control: YeelightConnection(device: mono))
        do {
            try await session.setColor(rgb: 0xFF0000)
            XCTFail("expected rejection")
        } catch YeelightError.unsupportedMethod {
            // Rejected on capability, not merely because the socket is closed.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class LocalAddressTests: XCTestCase {

    /// Music mode fails silently if we hand the device an address it cannot
    /// route back to, so the source address has to come from the routing table.
    func testPicksTheSourceAddressForTheRouteToTheDevice() {
        XCTAssertEqual(LocalAddress.forReaching(host: "127.0.0.1"), "127.0.0.1")
    }

    func testReturnsNilForSomethingThatIsNotAnIPv4Address() {
        XCTAssertNil(LocalAddress.forReaching(host: "not-an-address"))
    }
}
