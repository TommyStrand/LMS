import SwiftUI

struct VisualizerView: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let count = samples.count
            guard count > 1 else { return }

            let midY = size.height / 2
            let xStep = size.width / CGFloat(count - 1)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY + CGFloat(samples[0]) * midY * 0.9))
            for i in 1..<count {
                let x = CGFloat(i) * xStep
                let y = midY + CGFloat(samples[i]) * midY * 0.9
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // Glow
            context.stroke(path, with: .color(color.opacity(0.3)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

            // Fill below
            var fillPath = path
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(color.opacity(0.08)))
        }
    }
}
