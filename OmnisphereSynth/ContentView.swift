import SwiftUI

struct ContentView: View {
    @StateObject private var engine = AudioEngine()
    @State private var selectedPresetIndex = 0
    @State private var showControls = true

    var currentPreset: SynthPreset { SynthPreset.presets[selectedPresetIndex] }

    var body: some View {
        ZStack {
            Color(hex: "#0a0a14").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header

                // Waveform visualizer
                VisualizerView(
                    samples: engine.waveformSamples,
                    color: Color(hex: currentPreset.color)
                )
                .frame(height: 60)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Preset selector
                PresetSelectorView(selectedIndex: $selectedPresetIndex) { preset in
                    engine.applyPreset(preset)
                }
                .padding(.top, 8)

                // Main XY Pad
                XYPadView(engine: engine, preset: currentPreset)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity)

                // Controls panel
                if showControls {
                    ControlsView(engine: engine)
                        .padding(.top, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer(minLength: 8)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SUPERNOVA PAD")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: currentPreset.color).opacity(0.8))
                    .kerning(4)
                Text("Touch Synth")
                    .font(.system(size: 20, weight: .thin))
                    .foregroundColor(.white)
            }

            Spacer()

            // Active voice indicator
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(i < engine.voices.count
                              ? Color(hex: currentPreset.color)
                              : Color.white.opacity(0.1))
                        .frame(width: 6, height: 6)
                        .animation(.easeInOut(duration: 0.1), value: engine.voices.count)
                }
            }

            Button {
                withAnimation(.spring(response: 0.3)) {
                    showControls.toggle()
                }
            } label: {
                Image(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.3")
                    .font(.system(size: 18))
                    .foregroundColor(showControls ? Color(hex: currentPreset.color) : .white.opacity(0.5))
                    .padding(8)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

// MARK: - Color extension

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    ContentView()
}
