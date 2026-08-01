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

    /// The light bar has two engines with different abilities, so where a flow
    /// runs depends on what the flow asks for — not on where colour happens to
    /// live. A candle on a light bar belongs on the desk, not on the wall.
    func testAFlowRunsOnWhicheverEngineCanShowIt() {
        let bar = YeelightDevice(
            id: "bar", host: "1.1.1.1",
            support: ["get_prop", "set_power", "set_ct_abx", "set_bright", "start_cf", "stop_cf",
                      "bg_set_power", "bg_set_rgb", "bg_set_ct_abx", "bg_start_cf", "bg_stop_cf"]
        )
        XCTAssertEqual(bar.endpoint(for: .candle), .main, "a colour-temperature flow needs no colour")
        XCTAssertEqual(bar.endpoint(for: .rainbow), .background, "colour only exists there")
        XCTAssertEqual(bar.endpoint(for: .sunrise()), .main)
    }

    /// A bulb has one engine that does everything, so everything runs there.
    func testABulbRunsEveryFlowOnItsOnlyEngine() {
        let bulb = YeelightDevice(
            id: "bulb", host: "1.1.1.2",
            support: ["get_prop", "set_power", "set_rgb", "set_ct_abx", "start_cf", "stop_cf"]
        )
        XCTAssertEqual(bulb.endpoint(for: .rainbow), .main)
        XCTAssertEqual(bulb.endpoint(for: .candle), .main)
    }

    /// A white-only light can still run the flows that ask for no colour.
    func testAWhiteOnlyLightStillRunsColourTemperatureFlows() {
        let mono = YeelightDevice(
            id: "mono", host: "1.1.1.3",
            support: ["get_prop", "set_power", "set_bright", "set_ct_abx", "start_cf", "stop_cf"]
        )
        XCTAssertNil(mono.endpoint(for: .rainbow))
        XCTAssertEqual(mono.endpoint(for: .sunset()), .main)
    }

    func testAFlowKnowsWhetherItNeedsColour() {
        XCTAssertTrue(ColorFlow.rainbow.needsColor)
        XCTAssertTrue(ColorFlow.ocean.needsColor)
        XCTAssertFalse(ColorFlow.candle.needsColor)
        XCTAssertFalse(ColorFlow.sunrise().needsColor)
        XCTAssertFalse(ColorFlow.sunset().needsColor)
    }

    /// A hand-entered device advertises nothing, so nothing may be ruled out.
    func testUnknownCapabilitiesAreTreatedAsPermitted() {
        let manual = YeelightDevice(id: "m", host: "10.0.0.2")
        XCTAssertTrue(manual.supports(.setRGB))
        XCTAssertTrue(manual.supports(.backgroundSetPower))
        XCTAssertEqual(manual.colorMethod, .setRGB)
    }
}

/// Deriving a support list from what a device answers `get_prop` with, for
/// devices that never advertised one.
final class InferredCapabilityTests: XCTestCase {

    /// What `lamp15` answers: a background light, colour only on it, no
    /// moonlight mode. Values as captured from the device.
    private let lightBarProperties = [
        "power": "on", "main_power": "on", "bright": "80", "ct": "4000",
        "rgb": "", "hue": "", "sat": "", "color_mode": "2",
        "bg_power": "on", "bg_bright": "2", "bg_ct": "4000", "bg_rgb": "16711680",
        "bg_hue": "0", "bg_sat": "100", "bg_lmode": "1",
        "delayoff": "0", "music_on": "0", "active_mode": "", "nl_br": ""
    ]

    /// What a colour bulb answers: colour on the main light, no background.
    private let bulbProperties = [
        "power": "on", "main_power": "", "bright": "50", "ct": "4000",
        "rgb": "16711680", "hue": "0", "sat": "100", "color_mode": "1",
        "bg_power": "", "bg_bright": "", "bg_rgb": "", "music_on": "0"
    ]

    func testColourIsRuledOutWhenTheDeviceReportsNone() {
        let support = YeelightDevice.inferredSupport(fromProperties: lightBarProperties)
        let device = YeelightDevice(id: "m", host: "10.0.0.2", support: support)

        XCTAssertFalse(device.supports(.setRGB))
        XCTAssertFalse(device.supports(.setHSV))
        XCTAssertTrue(device.supports(.setColorTemperature))
        // Colour work still has somewhere to go: the background light.
        XCTAssertEqual(device.colorMethod, .backgroundSetRGB)
    }

    func testBackgroundLightIsRuledOutWhenTheDeviceReportsNone() {
        let support = YeelightDevice.inferredSupport(fromProperties: bulbProperties)
        let device = YeelightDevice(id: "m", host: "10.0.0.2", support: support)

        XCTAssertFalse(device.hasBackgroundLight)
        XCTAssertFalse(device.supports(.backgroundSetPower))
        XCTAssertEqual(device.colorMethod, .setRGB)
    }

    /// Nothing here is probeable, so all of it has to survive inference —
    /// otherwise learning would cost a device features it really has.
    func testMethodsThatCannotBeProbedAreKept() {
        let support = YeelightDevice.inferredSupport(fromProperties: lightBarProperties)
        let device = YeelightDevice(id: "m", host: "10.0.0.2", support: support)

        XCTAssertTrue(device.supports(.setPower))
        XCTAssertTrue(device.supports(.setBright))
        XCTAssertTrue(device.supports(.setScene))
        XCTAssertTrue(device.supports(.startColorFlow))
        XCTAssertTrue(device.supports(.cronAdd))
    }

    /// A device that answered nothing is unreadable, not featureless. Narrowing
    /// on that would strip a working light of its controls.
    func testAnEmptyAnswerLearnsNothing() {
        XCTAssertTrue(YeelightDevice.inferredSupport(fromProperties: [:]).isEmpty)
        XCTAssertTrue(YeelightDevice.inferredSupport(
            fromProperties: ["power": "", "main_power": "", "bright": "", "rgb": ""]).isEmpty)
    }

    /// Segments have no readable property, so they can only come from a real
    /// advertisement. Claiming them would send every ambient frame to a method
    /// the device rejects.
    func testSegmentsAreNeverInferred() {
        let support = YeelightDevice.inferredSupport(fromProperties: lightBarProperties)
        XCTAssertFalse(support.contains(YeelightMethod.setSegmentRGB.rawValue))
    }

    func testMusicModeFollowsTheMusicProperty() {
        XCTAssertTrue(YeelightDevice.inferredSupport(fromProperties: bulbProperties)
            .contains(YeelightMethod.setMusic.rawValue))
        var withoutMusic = bulbProperties
        withoutMusic["music_on"] = ""
        XCTAssertFalse(YeelightDevice.inferredSupport(fromProperties: withoutMusic)
            .contains(YeelightMethod.setMusic.rawValue))
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

    /// The sleep timer is set through `set_scene` but counted by the device, so
    /// `delayoff` is the only way to show how much of it is left.
    func testParsesTheDeviceSideCountdown() {
        XCTAssertEqual(YeelightState(properties: ["delayoff": "14"]).sleepMinutesRemaining, 14)
        // Zero is a real answer — "no timer running" — and must not read as nil.
        XCTAssertEqual(YeelightState(properties: ["delayoff": "0"]).sleepMinutesRemaining, 0)
        XCTAssertNil(YeelightState(properties: ["delayoff": ""]).sleepMinutesRemaining)
    }

    /// Only devices with a moonlight mode answer `active_mode` at all, so an
    /// empty value has to stay `nil` rather than becoming "not moonlight".
    func testMoonlightIsUnknownOnDevicesWithoutIt() {
        XCTAssertNil(YeelightState(properties: ["active_mode": "", "nl_br": ""]).isMoonlight)
        XCTAssertEqual(YeelightState(properties: ["active_mode": "1", "nl_br": "5"]).isMoonlight, true)
        XCTAssertEqual(YeelightState(properties: ["active_mode": "0"]).isMoonlight, false)
        XCTAssertEqual(YeelightState(properties: ["nl_br": "5"]).nightLightBrightness, 5)
    }

    func testParsesMusicSessionFlag() {
        XCTAssertEqual(YeelightState(properties: ["music_on": "1"]).isMusicModeOn, true)
        XCTAssertEqual(YeelightState(properties: ["music_on": "0"]).isMusicModeOn, false)
        XCTAssertNil(YeelightState(properties: ["music_on": ""]).isMusicModeOn)
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

// MARK: - Colour flow

final class ColorFlowTests: XCTestCase {

    /// The expression is a flat list of duration, mode, value, brightness.
    func testExpressionLayout() {
        let flow = ColorFlow(steps: [
            .init(duration: .milliseconds(1000), .colorTemperature(kelvin: 2700, brightness: 100)),
            .init(duration: .milliseconds(500), .color(rgb: 255, brightness: 10))
        ])
        XCTAssertEqual(flow.expression, "1000,2,2700,100,500,1,255,10")
    }

    /// Omitting brightness must send -1, which tells the device to keep its own.
    func testMissingBrightnessBecomesMinusOne() {
        let flow = ColorFlow(steps: [.init(.color(rgb: 0xFF0000))])
        XCTAssertEqual(flow.expression, "500,1,16711680,-1")
    }

    func testWaitStepUsesSleepMode() {
        let flow = ColorFlow(steps: [.init(duration: .seconds(5), .wait)])
        XCTAssertEqual(flow.expression, "5000,7,0,-1")
    }

    func testPoliceRunsForeverAndRestoresAfterwards() {
        let flow = ColorFlow.police
        XCTAssertEqual(flow.changeCount, 0, "0 means the device loops indefinitely")
        XCTAssertEqual(flow.completion, .restorePrevious)
        XCTAssertEqual(flow.steps.count, 2)
    }

    /// The firmware rejects steps under 50ms, so catch it before sending.
    func testRejectsStepShorterThanFirmwareAllows() {
        let flow = ColorFlow(steps: [.init(duration: .milliseconds(10), .color(rgb: 0))])
        XCTAssertThrowsError(try flow.validated())
    }

    func testRejectsEmptyFlow() {
        XCTAssertThrowsError(try ColorFlow(steps: []).validated())
    }

    func testRejectsOutOfRangeBrightness() {
        let flow = ColorFlow(steps: [.init(.color(rgb: 0, brightness: 0))])
        XCTAssertThrowsError(try flow.validated(), "0 is not a valid brightness; -1 or 1...100")
    }

    func testSunsetRunsOnceThenTurnsOff() {
        let flow = ColorFlow.sunset(over: .seconds(600))
        XCTAssertEqual(flow.completion, .turnOff)
        XCTAssertEqual(flow.changeCount, 2)
        XCTAssertNoThrow(try flow.validated())
    }

    func testReadyMadeFlowsAreAllValid() {
        for flow in [ColorFlow.police, .rainbow, .candle] {
            XCTAssertNoThrow(try flow.validated())
        }
    }
}

final class FlowRoutingTests: XCTestCase {

    /// The light bar has no RGB on its main light, so a flow has to go to the
    /// background light instead.
    func testFlowGoesToBackgroundLightOnColorTemperatureOnlyDevice() async {
        let bar = YeelightDevice(id: "bar", host: "127.0.0.1",
                                support: ["set_ct_abx", "bg_set_rgb", "bg_start_cf", "bg_set_power"])
        let connection = YeelightConnection(device: bar)

        // Not connected, so this fails at the transport — but only after routing
        // has picked bg_start_cf rather than rejecting the method outright.
        do {
            try await connection.startOnAvailableEndpoint(.police)
            XCTFail("expected a transport failure")
        } catch YeelightError.notConnected {
            // routed correctly
        } catch YeelightError.unsupportedMethod(let method) {
            XCTFail("routed to an unsupported method: \(method.rawValue)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFlowIsRejectedWhenDeviceHasNoColorAtAll() async {
        let mono = YeelightDevice(id: "mono", host: "127.0.0.1",
                                  support: ["set_power", "set_bright"])
        let connection = YeelightConnection(device: mono)
        do {
            try await connection.startOnAvailableEndpoint(.rainbow)
            XCTFail("expected rejection")
        } catch YeelightError.unsupportedMethod {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
