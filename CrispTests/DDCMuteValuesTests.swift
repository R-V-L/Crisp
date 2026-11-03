import XCTest

/// Headless tests for the VCP 0x8D mute values. `DDCMuteValues` compiles
/// directly into this test target, so no `@testable import Crisp` is needed.
final class DDCMuteValuesTests: XCTestCase {

    /// The standard VCP 0x8D range: 0 is unmuted, 1 is muted.
    func testStandardRange() {
        XCTAssertEqual(DDCMuteValues.from(max: 1), DDCMuteValues(mute: 1, unmute: 0))
    }

    /// The Acer G257HU and Samsung LS27A800U report max 2: 1 mutes, 2 unmutes,
    /// and 0 is ignored (measured 2026-11-03).
    func testTwoValueRange() {
        XCTAssertEqual(DDCMuteValues.from(max: 2), DDCMuteValues(mute: 1, unmute: 2))
    }

    /// An unknown range falls back to the 0x62 mute path rather than guessing.
    func testUnknownRangeIsUnsupported() {
        XCTAssertNil(DDCMuteValues.from(max: 0))
        XCTAssertNil(DDCMuteValues.from(max: 3))
    }
}
