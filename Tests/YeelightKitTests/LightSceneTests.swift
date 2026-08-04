import XCTest
@testable import YeelightKit

/// Scenes exist to dodge the "adjustments are refused while the light is off"
/// rule, so what they encode has to be exactly right.
final class LightSceneTests: XCTestCase {

    private func encoded(_ scene: LightScene) throws -> [String] {
        try scene.validated().parameters.map { "\($0.jsonValue)" }
    }

    func testColourTemperatureSceneCarriesBrightnessInTheSameCommand() throws {
        XCTAssertEqual(try encoded(.colorTemperature(kelvin: 4000, brightness: 73)),
                       ["ct", "4000", "73"])
    }

    func testColourSceneEncodesPackedRGB() throws {
        XCTAssertEqual(try encoded(.color(rgb: 0xFF4500, brightness: 30)),
                       ["color", "16729344", "30"])
    }

    func testHSVSceneKeepsHueAndSaturationSeparate() throws {
        XCTAssertEqual(try encoded(.hsv(hue: 200, saturation: 80, brightness: 55)),
                       ["hsv", "200", "80", "55"])
    }

    func testAutoDelayOffCarriesTheTimerInMinutes() throws {
        XCTAssertEqual(try encoded(.autoDelayOff(brightness: 40, minutes: 30)),
                       ["auto_delay_off", "40", "30"])
    }

    func testEverySceneReportsItsBrightness() {
        XCTAssertEqual(LightScene.color(rgb: 0, brightness: 12).brightness, 12)
        XCTAssertEqual(LightScene.hsv(hue: 0, saturation: 0, brightness: 34).brightness, 34)
        XCTAssertEqual(LightScene.colorTemperature(kelvin: 3000, brightness: 56).brightness, 56)
        XCTAssertEqual(LightScene.autoDelayOff(brightness: 78, minutes: 5).brightness, 78)
    }

    func testOnlyColourTemperatureScenesReportAKelvinValue() {
        XCTAssertEqual(LightScene.colorTemperature(kelvin: 3000, brightness: 50).colorTemperature, 3000)
        XCTAssertNil(LightScene.color(rgb: 0xFF0000, brightness: 50).colorTemperature)
    }

    /// Brightness 0 means "off" to the caller but is out of range for the
    /// device, which answers with a generic rejection.
    func testRejectsBrightnessOutsideTheDeviceRange() {
        XCTAssertThrowsError(try LightScene.colorTemperature(kelvin: 4000, brightness: 0).validated())
        XCTAssertThrowsError(try LightScene.color(rgb: 0, brightness: 101).validated())
    }

    func testRejectsColourTemperatureOutsideTheSupportedRange() {
        XCTAssertThrowsError(try LightScene.colorTemperature(kelvin: 1600, brightness: 50).validated())
        XCTAssertThrowsError(try LightScene.colorTemperature(kelvin: 6600, brightness: 50).validated())
    }

    func testRejectsAnRGBValueThatDoesNotFitInThreeBytes() {
        XCTAssertThrowsError(try LightScene.color(rgb: 0x1000000, brightness: 50).validated())
    }

    /// A saved preset is a stored scene, so every case has to survive the round
    /// trip — including the ones an application is unlikely to save today.
    func testEverySceneSurvivesBeingStoredAndReadBack() throws {
        let scenes: [LightScene] = [
            .color(rgb: 0xFF4500, brightness: 30),
            .hsv(hue: 200, saturation: 80, brightness: 60),
            .colorTemperature(kelvin: 2700, brightness: 100),
            .autoDelayOff(brightness: 40, minutes: 15)
        ]
        for scene in scenes {
            let data = try JSONEncoder().encode(scene)
            XCTAssertEqual(try JSONDecoder().decode(LightScene.self, from: data), scene)
        }
    }
}
