import XCTest
@testable import YeelightKit

final class DiscoveryParsingTests: XCTestCase {

    /// A real answer from a Monitor Light Bar Pro.
    private let lightBarResponse = """
    HTTP/1.1 200 OK\r
    Cache-Control: max-age=3600\r
    Location: yeelight://192.168.0.139:55443\r
    Server: POSIX UPnP/1.0 YGLC/1\r
    id: 0x000000001b4aa7fc\r
    model: lamp15\r
    fw_ver: 38\r
    support: get_prop set_default set_power toggle set_ct_abx set_bright bg_set_rgb bg_set_power\r
    power: off\r
    bright: 80\r
    name: \r\n
    """

    func testParsesDeviceFromSearchResponse() throws {
        let device = try XCTUnwrap(YeelightDiscovery.parse(response: lightBarResponse))

        XCTAssertEqual(device.id, "0x000000001b4aa7fc")
        XCTAssertEqual(device.host, "192.168.0.139")
        XCTAssertEqual(device.port, 55443)
        XCTAssertEqual(device.model, "lamp15")
        XCTAssertEqual(device.firmwareVersion, "38")
    }

    func testDisplayNameFallsBackToHostWhenNameIsEmpty() throws {
        let device = try XCTUnwrap(YeelightDiscovery.parse(response: lightBarResponse))
        XCTAssertEqual(device.displayName, "192.168.0.139")
    }

    func testRejectsResponseWithoutLocation() {
        XCTAssertNil(YeelightDiscovery.parse(response: "HTTP/1.1 200 OK\r\nid: 0x1\r\n"))
    }

    func testDefaultsPortWhenLocationOmitsIt() throws {
        let device = try XCTUnwrap(YeelightDiscovery.parse(
            response: "Location: yeelight://192.168.0.5\r\n"))
        XCTAssertEqual(device.port, 55443)
    }
}

final class DeviceCapabilityTests: XCTestCase {

    /// Monitor Light Bar: colour lives on the background light only.
    private let lightBar = YeelightDevice(
        id: "bar", host: "192.168.0.139",
        support: ["get_prop", "set_power", "set_ct_abx", "set_bright",
                  "bg_set_power", "bg_set_rgb"]
    )

    /// Colour bulb: colour on the main light, no background light at all.
    private let bulb = YeelightDevice(
        id: "bulb", host: "192.168.0.212",
        support: ["get_prop", "set_power", "set_bright", "set_rgb", "set_hsv", "set_music"]
    )

    func testColorMethodFollowsWhatTheDeviceAdvertises() {
        XCTAssertEqual(lightBar.colorMethod, .backgroundSetRGB)
        XCTAssertEqual(bulb.colorMethod, .setRGB)
    }

    func testBackgroundLightDetection() {
        XCTAssertTrue(lightBar.hasBackgroundLight)
        XCTAssertFalse(bulb.hasBackgroundLight)
    }

    func testUnsupportedMethodIsRejectedLocally() {
        XCTAssertFalse(lightBar.supports(.setRGB))
        XCTAssertTrue(lightBar.supports(.setColorTemperature))
    }

    /// A hand-entered device advertises nothing, so nothing may be ruled out.
    func testUnknownCapabilitiesAreTreatedAsPermitted() {
        let manual = YeelightDevice(id: "m", host: "10.0.0.2")
        XCTAssertTrue(manual.supports(.setRGB))
        XCTAssertTrue(manual.supports(.backgroundSetPower))
        XCTAssertEqual(manual.colorMethod, .setRGB)
    }
}

final class StateParsingTests: XCTestCase {

    /// Regression: on a light bar `power` describes the whole device and reads
    /// "on" whenever the ambient light is lit, so a switched-off bar showed as
    /// on until `main_power` was preferred.
    func testMainPowerWinsOverDevicePower() {
        let state = YeelightState(properties: ["power": "on", "main_power": "off"])
        XCTAssertEqual(state.isOn, false)
    }

    func testFallsBackToPowerWhenMainPowerIsAbsent() {
        XCTAssertEqual(YeelightState(properties: ["power": "on"]).isOn, true)
    }

    /// An unsupported property comes back as "" rather than an error.
    func testEmptyValuesAreNotParsedAsState() {
        let state = YeelightState(properties: ["main_power": "", "power": "on", "rgb": "", "bright": "50"])
        XCTAssertEqual(state.isOn, true, "empty main_power must not mask a real power value")
        XCTAssertNil(state.rgb)
        XCTAssertEqual(state.brightness, 50)
    }

    func testParsesBackgroundProperties() {
        let state = YeelightState(properties: [
            "bg_power": "on", "bg_bright": "67", "bg_rgb": "16711680", "bg_lmode": "1"
        ])
        XCTAssertEqual(state.backgroundIsOn, true)
        XCTAssertEqual(state.backgroundBrightness, 67)
        XCTAssertEqual(state.backgroundRGB, 0xFF0000)
        XCTAssertEqual(state.backgroundColorMode, .rgb)
    }

    /// Notifications are partial, so merging must not erase what is known.
    func testMergingKeepsValuesTheUpdateOmits() {
        let known = YeelightState(properties: ["power": "on", "bright": "80", "ct": "4000"])
        let merged = known.merging(YeelightState(properties: ["bright": "20"]))

        XCTAssertEqual(merged.brightness, 20)
        XCTAssertEqual(merged.isOn, true)
        XCTAssertEqual(merged.colorTemperature, 4000)
    }
}

final class ColorConversionTests: XCTestCase {

    func testPrimariesRoundTripExactly() {
        XCTAssertEqual(ColorConversion.rgb(hue: 0, saturation: 1), 0xFF0000)
        XCTAssertEqual(ColorConversion.rgb(hue: 1.0 / 3.0, saturation: 1), 0x00FF00)
        XCTAssertEqual(ColorConversion.rgb(hue: 2.0 / 3.0, saturation: 1), 0x0000FF)
    }

    func testZeroSaturationIsWhite() {
        for hue in stride(from: 0.0, through: 1.0, by: 0.25) {
            XCTAssertEqual(ColorConversion.rgb(hue: hue, saturation: 0), 0xFFFFFF)
        }
    }

    func testRoundTripStaysWithinEightBitPrecision() {
        for step in 0..<24 {
            let hue = Double(step) / 24.0
            for saturation in [0.25, 0.5, 0.75, 1.0] {
                let packed = ColorConversion.rgb(hue: hue, saturation: saturation)
                let back = ColorConversion.hueSaturation(fromRGB: packed)

                XCTAssertEqual(back.saturation, saturation, accuracy: 0.01)
                let drift = min(abs(back.hue - hue), 1 - abs(back.hue - hue))
                XCTAssertLessThan(drift, 0.01, "hue \(hue) sat \(saturation)")
            }
        }
    }

    func testOutOfRangeInputsAreClamped() {
        XCTAssertEqual(ColorConversion.rgb(hue: -1, saturation: 2), 0xFF0000)
        XCTAssertEqual(ColorConversion.rgb(hue: 2, saturation: -1), 0xFFFFFF)
    }
}

final class CommandValidationTests: XCTestCase {

    private func connection(support: Set<String>) -> YeelightConnection {
        YeelightConnection(device: YeelightDevice(id: "t", host: "127.0.0.1", support: support))
    }

    func testRejectsUnsupportedMethodWithoutTouchingTheNetwork() async {
        let client = connection(support: ["get_prop", "set_power"])
        do {
            try await client.setColor(rgb: 0xFF0000)
            XCTFail("expected the method to be rejected locally")
        } catch YeelightError.unsupportedMethod(let method) {
            XCTAssertEqual(method, .setRGB)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectsOutOfRangeBrightnessBeforeSending() async {
        let client = connection(support: ["set_bright"])
        do {
            try await client.setBrightness(150)
            XCTFail("expected validation to reject 150")
        } catch YeelightError.invalidArgument {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Guards the documented pacing constant against accidental change.
    func testMinimumCommandIntervalRespectsTheQuota() {
        XCTAssertGreaterThanOrEqual(YeelightConnection.minimumCommandInterval, .seconds(1))
    }
}
