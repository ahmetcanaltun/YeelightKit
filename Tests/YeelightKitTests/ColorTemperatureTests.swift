import XCTest
@testable import YeelightKit

/// Turning Kelvin into RGB, for the channels that have no `set_ct_abx` of their
/// own. Nothing here can be checked against a device — the light shows whatever
/// it is sent — so the fit is checked against what these temperatures are known
/// to look like.
final class ColorTemperatureTests: XCTestCase {

    private func components(_ rgb: Int) -> (r: Int, g: Int, b: Int) {
        ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
    }

    /// Candlelight-to-tungsten warmth: full red, muted green, little blue.
    func testAWarmTemperatureIsAmber() {
        let (r, g, b) = components(ColorConversion.rgb(kelvin: 2700))
        XCTAssertEqual(r, 255)
        XCTAssertTrue((150...220).contains(g), "green was \(g)")
        XCTAssertTrue(b < r, "blue \(b) should stay under red \(r)")
    }

    /// Daylight is near-white, and specifically not blue-cast enough to read as
    /// a colour rather than as white.
    func testDaylightIsNearlyWhite() {
        let (r, g, b) = components(ColorConversion.rgb(kelvin: 6500))
        XCTAssertTrue(r > 240 && g > 240 && b > 240, "\(r),\(g),\(b) is not white")
    }

    /// The bottom of the device's range has no blue in it at all.
    func testTheWarmestEndHasNoBlue() {
        XCTAssertEqual(components(ColorConversion.rgb(kelvin: 1700)).b, 0)
    }

    func testWarmerIsAlwaysBluerAtTheTopAndRedderAtTheBottom() {
        var previousBlue = -1
        for kelvin in stride(from: 1700, through: 6500, by: 200) {
            let blue = components(ColorConversion.rgb(kelvin: kelvin)).b
            XCTAssertGreaterThanOrEqual(blue, previousBlue,
                                        "blue fell going from cooler to warmer at \(kelvin) K")
            previousBlue = blue
        }
    }

    /// The fit's logarithms are only defined over a range; outside it the
    /// answer has to be the nearest one inside rather than a NaN.
    func testTemperaturesOutsideTheFitAreClamped() {
        XCTAssertEqual(ColorConversion.rgb(kelvin: 0), ColorConversion.rgb(kelvin: 1000))
        XCTAssertEqual(ColorConversion.rgb(kelvin: 100_000), ColorConversion.rgb(kelvin: 40000))
    }

    func testEveryTemperatureFitsInThreeBytes() {
        for kelvin in stride(from: 1000, through: 12000, by: 100) {
            let rgb = ColorConversion.rgb(kelvin: kelvin)
            XCTAssertTrue((0...0xFFFFFF).contains(rgb), "\(kelvin) K produced \(rgb)")
        }
    }
}
