import Testing

@testable import DAGGraphUI

/// Tests for the activity footer's formatters (issue #134): the adaptive elapsed clock and the
/// floor-guarded cost, the two bits of display logic worth pinning independently of SwiftUI rendering.
@Suite("NodeActivityFooter formatting")
struct NodeActivityFooterTests {

    @Test("elapsed drops to bare seconds under a minute")
    func elapsedSecondsOnly() {
        #expect(NodeActivityFooter.formatElapsed(.seconds(0)) == "0s")
        #expect(NodeActivityFooter.formatElapsed(.seconds(8)) == "8s")
        #expect(NodeActivityFooter.formatElapsed(.seconds(59)) == "59s")
    }

    @Test("elapsed shows m:ss in the minutes range")
    func elapsedMinutes() {
        #expect(NodeActivityFooter.formatElapsed(.seconds(60)) == "1:00")
        #expect(NodeActivityFooter.formatElapsed(.seconds(83)) == "1:23")
    }

    @Test("elapsed shows h:mm:ss past an hour")
    func elapsedHours() {
        #expect(NodeActivityFooter.formatElapsed(.seconds(3723)) == "1:02:03")
    }

    @Test("elapsed never goes negative")
    func elapsedClampsNegative() {
        #expect(NodeActivityFooter.formatElapsed(.seconds(-5)) == "0s")
    }

    @Test("cost floors a sub-cent run to $0.01 so it never reads as $0.00")
    func costFloor() {
        #expect(NodeActivityFooter.formatCost(0.002) == "$0.01")
        #expect(NodeActivityFooter.formatCost(0.0) == "$0.01")
    }

    @Test("cost renders cents at two places")
    func costTwoPlaces() {
        #expect(NodeActivityFooter.formatCost(0.04) == "$0.04")
        #expect(NodeActivityFooter.formatCost(1.5) == "$1.50")
    }
}
