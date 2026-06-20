import CoreGraphics
import DAGGraphUI
import Testing

/// Tests for `DAGGraphMetrics`, the centralised layout vocabulary `DAGGraphView` reads when laying out
/// node cards and stroking dependency edges. One assertion per default-value identity, so a regression
/// in any single property surfaces as its own failure. Ported from the prototype.
@Suite("DAGGraphMetrics")
struct DAGGraphMetricsTests {

    @Test("default exposes the canonical layout values")
    func defaultExposesCanonicalLayoutValues() {
        let metrics = DAGGraphMetrics.default

        #expect(metrics.edgeStrokeWidth == 2)
        #expect(metrics.nodeWidth == 168)
        #expect(metrics.nodeMinHeight == 64)
        #expect(metrics.nodeCornerRadius == 12)
        #expect(metrics.nodeBorderWidth == 3)
        #expect(metrics.rowGap == 56)
        #expect(metrics.columnGap == 24)
        #expect(metrics.outerPadding == 24)
    }

    @Test("default exposes a 1.2 s pulseDuration — the breathing-rhythm cadence for the .inProgress pulse")
    func defaultPulseDurationIsBreathingRhythm() {
        #expect(DAGGraphMetrics.default.pulseDuration == 1.2)
    }
}
