import Testing

@testable import DAGGraphUI

/// Tests for `NodeActivity`'s formatters (issue #134): the adaptive elapsed clock and the floor-guarded
/// cost — the two bits of display logic, shared by the compact footer and the prominent panel, worth
/// pinning independently of SwiftUI rendering.
@Suite("NodeActivity formatting")
struct NodeActivityFormattingTests {

    @Test("elapsed drops to bare seconds under a minute")
    func elapsedSecondsOnly() {
        #expect(NodeActivity.formatElapsed(.seconds(0)) == "0s")
        #expect(NodeActivity.formatElapsed(.seconds(8)) == "8s")
        #expect(NodeActivity.formatElapsed(.seconds(59)) == "59s")
    }

    @Test("elapsed shows m:ss in the minutes range")
    func elapsedMinutes() {
        #expect(NodeActivity.formatElapsed(.seconds(60)) == "1:00")
        #expect(NodeActivity.formatElapsed(.seconds(83)) == "1:23")
    }

    @Test("elapsed shows h:mm:ss past an hour")
    func elapsedHours() {
        #expect(NodeActivity.formatElapsed(.seconds(3723)) == "1:02:03")
    }

    @Test("elapsed never goes negative")
    func elapsedClampsNegative() {
        #expect(NodeActivity.formatElapsed(.seconds(-5)) == "0s")
    }

    @Test("cost floors a sub-cent run to $0.01 so it never reads as $0.00")
    func costFloor() {
        #expect(NodeActivity.formatCost(0.002) == "$0.01")
        #expect(NodeActivity.formatCost(0.0) == "$0.01")
    }

    @Test("cost renders cents at two places")
    func costTwoPlaces() {
        #expect(NodeActivity.formatCost(0.04) == "$0.04")
        #expect(NodeActivity.formatCost(1.5) == "$1.50")
    }
}
