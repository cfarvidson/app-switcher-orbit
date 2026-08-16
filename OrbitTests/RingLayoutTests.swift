import AppKit
import XCTest

final class RingLayoutTests: XCTestCase {

    func testComputeEmpty() {
        XCTAssertEqual(RingLayout.compute(preferred: [], others: []), [])
    }

    func testSinglePreferredItemLandsAtTwelveOClock() {
        let result = RingLayout.compute(
            preferred: [(.dictation, 90)],
            others: []
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].item, .dictation)
        XCTAssertEqual(result[0].angleDegrees, 0)
        XCTAssertTrue(result[0].isAnchored)
    }

    func testPreferenceZeroAlwaysClaimsTwelveOClock() {
        let others = [fixtureApp(pid: 1, name: "A"), fixtureApp(pid: 2, name: "B"), fixtureApp(pid: 3, name: "C")]
        let result = RingLayout.compute(
            preferred: [(.dictation, 0)],
            others: others
        )
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].item, .dictation)
        XCTAssertEqual(result[0].angleDegrees, 0)
        XCTAssertTrue(result[0].isAnchored)
        XCTAssertEqual(result.map(\.angleDegrees), [0, 90, 180, 270])
    }

    func testPreferredItemTakesNearestSlot() {
        let others = [fixtureApp(pid: 1, name: "A"), fixtureApp(pid: 2, name: "B"), fixtureApp(pid: 3, name: "C")]
        let result = RingLayout.compute(
            preferred: [(.dictation, 100)],
            others: others
        )
        // n=4, step=90. 100° is closest to slot 1 at 90°.
        let dictation = result.first { $0.item == .dictation }
        XCTAssertEqual(dictation?.angleDegrees, 90)
        XCTAssertEqual(dictation?.isAnchored, true)
    }

    func testDuplicatePreferencesTakeAdjacentSlots() {
        let a = fixtureApp(pid: 1, name: "A")
        let b = fixtureApp(pid: 2, name: "B")
        let result = RingLayout.compute(
            preferred: [(a, 0), (b, 0)],
            others: []
        )
        XCTAssertEqual(result.count, 2)
        let angles = Set(result.map(\.angleDegrees))
        XCTAssertEqual(angles, [0, 180], "Two claims on 0° must land on adjacent even slots, not stack")
        XCTAssertTrue(result.allSatisfy(\.isAnchored))
    }

    func testOthersFillUnclaimedSlotsInGivenOrder() {
        let a = fixtureApp(pid: 1, name: "A")
        let b = fixtureApp(pid: 2, name: "B")
        let result = RingLayout.compute(
            preferred: [(.dictation, 0)],
            others: [a, b]
        )
        XCTAssertEqual(result.map(\.angleDegrees), [0, 120, 240])
        XCTAssertEqual(result[0].item, .dictation)
        XCTAssertEqual(result[1].item, a)
        XCTAssertEqual(result[2].item, b)
        XCTAssertFalse(result[1].isAnchored)
        XCTAssertFalse(result[2].isAnchored)
    }

    func testClosestClaimWinsContestedSlot() {
        let near = fixtureApp(pid: 1, name: "Near")
        let far = fixtureApp(pid: 2, name: "Far")
        let result = RingLayout.compute(
            preferred: [(far, 40), (near, 5)],
            others: []
        )
        // n=2, step=180. Both want slot 0. Residual(5, 0)=5 beats residual(40, 0)=40.
        let nearPos = result.first { $0.item == near }
        XCTAssertEqual(nearPos?.angleDegrees, 0)
        let farPos = result.first { $0.item == far }
        XCTAssertEqual(farPos?.angleDegrees, 180)
    }

    func testNextAnchorAngleEmptyIsTwelveOClock() {
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: []), 0)
    }

    func testNextAnchorAngleOppositeSingleAnchor() {
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [0]), 180)
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [90]), 270)
    }

    func testNextAnchorAngleMidpointOfLargestGap() {
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [0, 180]), 90)
    }

    func testNextAnchorAngleDuplicateAnglesDoNotLookLikeAFullCircle() {
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [0, 0]), 180)
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [45, 45, 45]), 225)
    }

    func testNextAnchorAngleWrapAroundGap() {
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [0, 10, 20]), 190)
    }

    func testNextAnchorAngleNormalizesNegativeAndOversizeInput() {
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [-90]), 90)
        XCTAssertEqual(RingLayout.nextAnchorAngle(existingAngles: [360]), 180)
    }

    private func fixtureApp(pid: pid_t, name: String) -> OrbitItem {
        .app(
            RunningApp(
                id: pid,
                name: name,
                bundleIdentifier: "test.\(name.lowercased())",
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                app: NSRunningApplication.current
            )
        )
    }
}
