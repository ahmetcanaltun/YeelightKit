import XCTest
@testable import YeelightKit

/// The segment effects are pure generators, so everything about them can be
/// checked here — which matters, because the only other way to see one is to
/// point a camera at a light bar.
final class SegmentEffectTests: XCTestCase {

    private let zones = 3 // what the Monitor Light Bar Pro has

    func testEveryEffectFillsExactlyTheSectionsItWasAskedFor() {
        for effect in SegmentEffect.allCases {
            for count in [1, 3, 8] {
                XCTAssertEqual(effect.colors(zones: count, at: 0.4).count, count,
                               "\(effect.rawValue) at \(count) zones")
            }
        }
    }

    /// A light with no segments still gets the animation, as one colour.
    func testASingleZoneIsMeaningful() {
        for effect in SegmentEffect.allCases {
            XCTAssertEqual(effect.colors(zones: 1, at: 1.1).count, 1)
            XCTAssertEqual(effect.colors(zones: 0, at: 1.1).count, 1, "zero must not mean no output")
        }
    }

    /// Frames are a function of time alone, so a caller may drop frames or
    /// change its rate without the animation drifting.
    func testAFullPeriodReturnsToWhereItStarted() {
        for effect in SegmentEffect.allCases {
            let period = effect.period.seconds
            for time in [0.0, 0.37, 1.2] {
                let now = effect.colors(zones: zones, at: time)
                let later = effect.colors(zones: zones, at: time + period)
                for (a, b) in zip(now, later) {
                    // A degree of rounding is unavoidable in 8-bit channels.
                    XCTAssertEqual(Double(a), Double(b), accuracy: 0x010101,
                                   "\(effect.rawValue) at \(time)s")
                }
            }
        }
    }

    /// Whether `0x000000` switches a section off or leaves it on its last
    /// colour is unsettled on the only device with segments, so no effect may
    /// depend on the answer.
    func testNoSectionIsEverSentBlack() {
        for effect in SegmentEffect.allCases {
            for step in 0..<120 {
                let time = Double(step) * 0.05
                for color in effect.colors(zones: zones, at: time) {
                    XCTAssertNotEqual(color, 0, "\(effect.rawValue) went black at \(time)s")
                }
            }
        }
    }

    func testColoursStayInsideTwentyFourBits() {
        for effect in SegmentEffect.allCases {
            for step in 0..<60 {
                for color in effect.colors(zones: zones, at: Double(step) * 0.1) {
                    XCTAssertGreaterThanOrEqual(color, 0)
                    XCTAssertLessThanOrEqual(color, 0xFFFFFF)
                }
            }
        }
    }

    /// The point of the whole feature: the bright part has to *move*, and move
    /// in section order, or the light is just changing colour.
    func testTheSweepsBrightestSectionTravelsAlongTheLight() {
        let effect = SegmentEffect.sweep
        let period = effect.period.seconds

        func brightestSection(at time: Double) -> Int {
            let colors = effect.colors(zones: 8, at: time)
            let luminance = colors.map { ($0 >> 16 & 0xFF) + ($0 >> 8 & 0xFF) + ($0 & 0xFF) }
            return luminance.firstIndex(of: luminance.max()!)!
        }

        // Sampled across one pass, the brightest section only ever moves
        // forwards — apart from the single wrap back to the start.
        // Stopping just short of a full period: at exactly one period the band
        // is back where it started, which would read as a wrap.
        var wraps = 0
        var previous = brightestSection(at: 0)
        for step in 1..<40 {
            let current = brightestSection(at: Double(step) / 40 * period)
            if current < previous { wraps += 1 }
            previous = current
        }
        XCTAssertLessThanOrEqual(wraps, 1, "the band should travel one way, not jitter")
        XCTAssertGreaterThan(previous, 0, "the band never left the first section")
    }

    /// A rainbow that shows one colour at a time is a colour flow, which the
    /// device can already do by itself. Its whole reason to exist here is that
    /// the sections differ.
    func testTheRainbowShowsDifferentHuesAtOnce() {
        let colors = SegmentEffect.rainbow.colors(zones: zones, at: 0)
        XCTAssertEqual(Set(colors).count, zones)
    }

    /// Police alternates by section and swaps ends half a period later.
    func testPoliceSwapsEnds() {
        let effect = SegmentEffect.police
        let first = effect.colors(zones: 2, at: 0)
        let second = effect.colors(zones: 2, at: effect.period.seconds / 2)

        XCTAssertNotEqual(first[0], first[1], "the two ends should differ")
        XCTAssertEqual(first[0], second[1])
        XCTAssertEqual(first[1], second[0])
    }
}
