import SwiftUI

public struct PulsingNodeView<Content: View>: View {
    let color: Color
    let metrics: DAGGraphMetrics
    let selectedColor: Color
    let isPulsing: Bool
    let isSlashed: Bool
    let isSelected: Bool

    @State private var pulseActive: Bool = false

    @ViewBuilder var content: () -> Content

    public init(
        color: Color,
        metrics: DAGGraphMetrics,
        selectedColor: Color? = nil,
        isPulsing: Bool = false,
        isSlashed: Bool = false,
        isSelected: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.color = color
        self.metrics = metrics
        self.selectedColor = selectedColor ?? color
        self.isPulsing = isPulsing
        self.isSlashed = isSlashed
        self.isSelected = isSelected
        self.content = content
    }

    var restingFillOpacity: Double {
        isPulsing ? 0.4 : 0.1
    }

    var fillOpacity: Double {
        (isPulsing && pulseActive) ? 0.2 : restingFillOpacity
    }

    var restingBorderOpacity: Double {
        isPulsing ? 1.0 : 0.6
    }

    var borderOpacity: Double {
        (isPulsing && pulseActive) ? 0.5 : restingBorderOpacity
    }

    public var body: some View {
        content()
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: metrics.nodeCornerRadius)
                    .fill(color.opacity(fillOpacity))
                    .stroke(
                        color.opacity(borderOpacity),
                        lineWidth: metrics.nodeBorderWidth
                    )
                    .animation(
                        isPulsing
                        ? .easeInOut(duration: metrics.pulseDuration)
                            .repeatForever(autoreverses: true)
                        : .default,
                        value: pulseActive
                    )
                if isSlashed {
                    SlashLine()
                        .stroke(color.opacity(0.5), lineWidth: metrics.edgeStrokeWidth * 2)
                        .clipShape(RoundedRectangle(cornerRadius: metrics.nodeCornerRadius))
                }
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: metrics.nodeCornerRadius)
                    .inset(by: -(metrics.nodeBorderWidth * 1.5))
                    .stroke(selectedColor, lineWidth: metrics.nodeBorderWidth * 2)
                    .blur(radius: metrics.nodeBorderWidth * 2.0)
            }
        }
        .onAppear {
            if isPulsing {
                pulseActive = true
            }
        }
        .onChange(of: isPulsing) { _, newIsPulsing in
            pulseActive = newIsPulsing
        }
    }
}

/// Diagonal line from the rect's bottom-left to its top-right; the caller clips it to the card.
private struct SlashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

#if DEBUG

#Preview("All") {
    @Previewable @State var isPulsing: Bool = false
    @Previewable @State var isSlashed: Bool = false
    @Previewable @State var isSelected: Bool = false

    let cases: [(Color, Color?, String)] = [
        (.green, nil, "Green"),
        (.yellow, nil, "Yellow"),
        (.orange, nil, "Orange"),
        (.indigo, nil, "Indigo"),
        (.blue, .white, "Blue / White"),
        (.red, nil, "Red"),
    ]

    VStack(spacing: 20) {
        HStack {
            Button("Pulsing") { isPulsing.toggle() }
            Button("Slashed") { isSlashed.toggle() }
            Button("Selected") { isSelected.toggle() }
        }
        ForEach(0..<cases.count, id: \.self) { i in
            let (color, selectedColor, title) = cases[i]
            PulsingNodeView(
                color: color,
                metrics: .default,
                selectedColor: selectedColor,
                isPulsing: isPulsing,
                isSlashed: isSlashed,
                isSelected: isSelected
            ) {
                Text(title)
                    .padding()
                    .frame(minWidth: 120)
            }
            .padding(6)
        }
    }
    .padding(Spacing.l)
}

#endif
