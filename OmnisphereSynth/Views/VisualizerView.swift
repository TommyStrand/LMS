import SwiftUI

struct VisualizerView: View {
    let samples: [Float]
    let color: Color
    let theme: AppTheme

    var body: some View {
        Canvas { context, size in
            let count = samples.count
            guard count > 1 else { return }

            let midY   = size.height / 2
            let xStep  = size.width / CGFloat(count - 1)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY + CGFloat(samples[0]) * midY * 0.9))
            for i in 1..<count {
                let x = CGFloat(i) * xStep
                let y = midY + CGFloat(samples[i]) * midY * 0.9
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // Glow layers (intensified for Radar/Cyber themes)
            let glowWidth: CGFloat = theme.id == "radar" || theme.id == "cyber" ? 10 : 6
            context.stroke(path, with: .color(color.opacity(0.25)),
                           style: StrokeStyle(lineWidth: glowWidth, lineCap: .round))
            context.stroke(path, with: .color(color.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.stroke(path, with: .color(theme.primaryText.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))

            // Fill
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.07)))
        }
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }
}
