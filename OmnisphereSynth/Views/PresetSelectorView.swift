import SwiftUI

struct PresetSelectorView: View {
    @Binding var selectedIndex: Int
    @EnvironmentObject var themeManager: ThemeManager
    let onSelect: (SynthPreset) -> Void

    var body: some View {
        let theme = themeManager.current
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(SynthPreset.presets.enumerated()), id: \.offset) { idx, preset in
                    PresetChip(
                        preset: preset,
                        isSelected: idx == selectedIndex,
                        theme: theme
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
    let theme: AppTheme

    private var accentColor: Color { theme.accent(for: Color(hex: preset.color)) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                    .fill(isSelected ? accentColor.opacity(0.85) : theme.panelBackground)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                            .strokeBorder(accentColor.opacity(isSelected ? 1 : 0.4),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                    .shadow(color: isSelected ? accentColor.opacity(0.5) : .clear, radius: 10)

                OscIcon(waveform: preset.osc1Waveform,
                        color: isSelected ? theme.primaryText : accentColor)
                    .frame(width: 32, height: 20)
            }

            Text(preset.name)
                .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                .foregroundColor(isSelected ? accentColor : theme.secondaryText)
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
                for x in stride(from: 0.0, through: Double(size.width), by: 1) {
                    let y = Double(mid) - sin(x / Double(size.width) * 2 * .pi) * Double(mid) * 0.8
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else       { path.addLine(to: CGPoint(x: x, y: y)) }
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
                for x in stride(from: 1.0, through: Double(size.width), by: 2) {
                    rng = rng &* 1664525 &+ 1013904223
                    let y = Double(mid) + (Double(Int32(bitPattern: rng)) / Double(Int32.max)) * Double(mid) * 0.8
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}
