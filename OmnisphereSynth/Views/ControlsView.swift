import SwiftUI

struct ControlsView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        let preset = engine.currentPreset
        let color  = Color(hex: preset.color)

        VStack(spacing: 12) {
            // Row 1 – always visible
            HStack(spacing: 16) {
                KnobView(label: "REVERB", value: preset.reverbMix, color: color) { v in
                    engine.setReverb(v)
                }
                KnobView(label: "DELAY", value: preset.delayMix, color: color) { v in
                    engine.setDelay(v)
                }
                KnobView(label: "FILTER", value: preset.filterCutoff / 20000, color: color) { v in
                    engine.currentPreset.filterCutoff = v * 20000
                }
                KnobView(label: "RESON", value: preset.filterResonance, color: color) { v in
                    engine.currentPreset.filterResonance = v
                }
            }

            if preset.isOrgan {
                OrganControlsRow(engine: engine, color: color)
            } else {
                ADSRRow(engine: engine, color: color)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Organ FX row

struct OrganControlsRow: View {
    @ObservedObject var engine: AudioEngine
    let color: Color

    var body: some View {
        let preset = engine.currentPreset
        HStack(spacing: 0) {
            // Distortion section
            VStack(spacing: 4) {
                Text("DISTORTION")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(color.opacity(0.7))
                    .kerning(1.5)
                HStack(spacing: 16) {
                    KnobView(label: "DRIVE", value: preset.distortionAmount, color: color) { v in
                        engine.setDistortion(v)
                    }
                    KnobView(label: "BITE", value: preset.filterCutoff / 20000, color: color) { v in
                        engine.currentPreset.filterCutoff = v * 20000
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 12)

            // Shimmer section
            VStack(spacing: 4) {
                Text("SHIMMER")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(color.opacity(0.7))
                    .kerning(1.5)
                HStack(spacing: 16) {
                    KnobView(label: "AMOUNT", value: preset.shimmerAmount, color: color) { v in
                        engine.setShimmer(v)
                    }
                    KnobView(label: "TREMUL", value: preset.tremulantDepth, color: color) { v in
                        engine.currentPreset.tremulantDepth = v
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Synth ADSR row

struct ADSRRow: View {
    @ObservedObject var engine: AudioEngine
    let color: Color

    var body: some View {
        let preset = engine.currentPreset
        HStack(spacing: 16) {
            ADSRView(label: "A", value: preset.attack / 3.0, color: color) { v in
                engine.currentPreset.attack = v * 3.0
            }
            ADSRView(label: "D", value: preset.decay / 2.0, color: color) { v in
                engine.currentPreset.decay = v * 2.0
            }
            ADSRView(label: "S", value: preset.sustain, color: color) { v in
                engine.currentPreset.sustain = v
            }
            ADSRView(label: "R", value: preset.release / 4.0, color: color) { v in
                engine.currentPreset.release = v * 4.0
            }
        }
    }
}

// MARK: - Knob

struct KnobView: View {
    let label: String
    let value: Float
    let color: Color
    let onChange: (Float) -> Void

    @State private var lastDragY: CGFloat = 0

    private let minAngle: Double = -135
    private let maxAngle: Double =  135

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: CGFloat(value))
                    .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(Color(hex: "#1a1a2e"))
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: 3, height: 10)
                            .offset(y: -12)
                            .rotationEffect(.degrees(mappedAngle))
                    )
                    .shadow(color: color.opacity(0.4), radius: 4)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let delta = Float(lastDragY - v.location.y) * 0.005
                        lastDragY = v.location.y
                        onChange(max(0, min(1, value + delta)))
                    }
                    .onEnded { _ in lastDragY = 0 }
            )

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .kerning(1.5)
        }
    }

    private var mappedAngle: Double {
        Double(value) * (maxAngle - minAngle) + minAngle
    }
}

// MARK: - ADSR Slider

struct ADSRView: View {
    let label: String
    let value: Float
    let color: Color
    let onChange: (Float) -> Void

    @State private var lastDragY: CGFloat = 0

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 36, height: 64)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [color, color.opacity(0.4)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 28, height: max(4, CGFloat(value) * 56))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let delta = Float(lastDragY - v.location.y) * 0.007
                        lastDragY = v.location.y
                        onChange(max(0.001, min(1, value + delta)))
                    }
                    .onEnded { _ in lastDragY = 0 }
            )

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .kerning(1.5)
        }
    }
}
