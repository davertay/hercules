import CoreGraphics
import Foundation

/// Layout vocabulary for the rect-based DAG view (`DAGGraphView`). Centralised so every consumer reads
/// the same numbers — a re-skin is one edit. Split into node sizing, inter-node spacing, and edge
/// styling. Ported verbatim from the prototype.
public struct DAGGraphMetrics: Sendable {

    /// Line width each dependency bezier (and the matching arrowhead's derived base width) is drawn
    /// with. 2 pt matches the layered-DAG convention (graphviz `penwidth`, dagre default).
    public let edgeStrokeWidth: CGFloat

    /// Width of the rounded-rectangle node card — wide enough for a typical title on one or two lines
    /// at the body font, with padding for the number badge.
    public let nodeWidth: CGFloat

    /// Minimum height of the node card. Actual height is content-driven (title line count) but never
    /// falls below this floor, so a row of mixed-length titles keeps a uniform rhythm.
    public let nodeMinHeight: CGFloat

    /// Corner radius of the node card — rounded enough to read as a card, square enough that the four
    /// flat edges stay distinct as entry/exit surfaces for dependency lines.
    public let nodeCornerRadius: CGFloat

    /// Border width of the node card. The status colour strokes the outline at this width over a
    /// neutral fill, keeping the title legible against any status.
    public let nodeBorderWidth: CGFloat

    /// Vertical gap between consecutive levels (rows). The bezier between two levels controls at the
    /// row midline, so a generous gap keeps the curve readable.
    public let rowGap: CGFloat

    /// Horizontal gap between nodes within a level. Tighter than `rowGap`: same-level peers are usually
    /// unrelated (no edge between them), so a compact spacing keeps each row from sprawling.
    public let columnGap: CGFloat

    /// Outer padding around the DAG content, giving the outermost row/column a buffer against the
    /// surrounding ScrollView's clipping rect.
    public let outerPadding: CGFloat

    /// Cadence (seconds) for the `.inProgress` amber-pulse animation. Each cycle is one fade-out plus
    /// one fade-in, so the perceived blink is half this value. 1.2 s sits in the "alive but not
    /// anxious" band (slower than a ~1 s resting heart rate, faster than the ~2 s "stuck" threshold).
    public let pulseDuration: TimeInterval

    public init(
        edgeStrokeWidth: CGFloat = 2,
        nodeWidth: CGFloat = 168,
        nodeMinHeight: CGFloat = 64,
        nodeCornerRadius: CGFloat = 12,
        nodeBorderWidth: CGFloat = 3,
        rowGap: CGFloat = 56,
        columnGap: CGFloat = 24,
        outerPadding: CGFloat = 24,
        pulseDuration: TimeInterval = 1.2
    ) {
        self.edgeStrokeWidth = edgeStrokeWidth
        self.nodeWidth = nodeWidth
        self.nodeMinHeight = nodeMinHeight
        self.nodeCornerRadius = nodeCornerRadius
        self.nodeBorderWidth = nodeBorderWidth
        self.rowGap = rowGap
        self.columnGap = columnGap
        self.outerPadding = outerPadding
        self.pulseDuration = pulseDuration
    }

    /// Canonical default metrics tuned for a typical Workflow pane (10–15 node DAG, 3–4 levels deep,
    /// ~600 pt pane width).
    public static let `default` = DAGGraphMetrics()
}
