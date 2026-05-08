import SwiftUI

struct PresetSelectorView: View {
    @Binding var selectedIndex: Int
    let onSelect: (SynthPreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(SynthPreset.presets.enumerated()), id: \.offset) { idx, preset in
                    PresetChip(
                        preset: preset,
                        isSelected: idx == selectedIndex
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedIndex = idx
                        }
                        onSelect(preset)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }
}

struct PresetChip: View {
    let preset: SynthPreset
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isSelected
                            ? Color(hex: preset.color).opacity(0.9)
                            : Color.white.opacity(0.08)
                    )
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                Color(hex: preset.color).opacity(isSelected ? 1 : 0.3),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(color: isSelected ? Color(hex: preset.color).opacity(0.6) : .clear, radius: 10)

                OscIcon(waveform: preset.osc1Waveform, color: isSelected ? .white : Color(hex: preset.color))
                    .frame(width: 32, height: 20)
            }
            Text(preset.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? Color(hex: preset.color) : .white.opacity(0.5))
                .lineLimit(1)
                .frame(width: 72)
        }
        .scaleEffect(isSelected ? 1.05 : 1.0)
    }
}

struct OscIcon: View {
    let waveform: SynthPreset.Waveform
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let mid = size.height / 2
            switch waveform {
            case .sine:
                for x in stride(from: 0, through: size.width, by: 1) {
                    let y = mid - sin(x / size.width * 2 * .pi) * mid * 0.8
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            case .triangle:
                path.move(to: CGPoint(x: 0, y: mid))
                path.addLine(to: CGPoint(x: size.width * 0.25, y: mid * 0.2))
                path.addLine(to: CGPoint(x: size.width * 0.75, y: mid * 1.8))
                path.addLine(to: CGPoint(x: size.width, y: mid))
            case .sawtooth:
                path.move(to: CGPoint(x: 0, y: mid * 1.8))
                path.addLine(to: CGPoint(x: size.width * 0.5, y: mid * 0.2))
                path.addLine(to: CGPoint(x: size.width * 0.5, y: mid * 1.8))
                path.addLine(to: CGPoint(x: size.width, y: mid * 0.2))
            case .square:
                path.move(to: CGPoint(x: 0, y: mid * 0.2))
                path.addLine(to: CGPoint(x: size.width * 0.5, y: mid * 0.2))
                path.addLine(to: CGPoint(x: size.width * 0.5, y: mid * 1.8))
                path.addLine(to: CGPoint(x: size.width, y: mid * 1.8))
            case .noise:
                var rng: UInt32 = 12345
                path.move(to: CGPoint(x: 0, y: mid))
                for x in stride(from: 1, through: size.width, by: 2) {
                    rng = rng &* 1664525 &+ 1013904223
                    let y = mid + (CGFloat(Int32(bitPattern: rng)) / CGFloat(Int32.max)) * mid * 0.8
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}
