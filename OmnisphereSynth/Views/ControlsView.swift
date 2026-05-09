import SwiftUI

struct ControlsView: View {
    @ObservedObject var engine: AudioEngine
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let preset = engine.currentPreset
        let color  = Color(hex: preset.color)
        let theme  = themeManager.current

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

            // Row 2 – voice-specific controls
            switch preset.voiceMode {
            case .organChurch, .hammondB3:
                OrganControlsRow(engine: engine, color: color)
            case .rhodes:
                RhodesControlsRow(engine: engine, color: color)
            case .synth:
                ADSRRow(engine: engine, color: color)
            }

            // Row 3 – Texture (always visible)
            TextureRow(engine: engine, color: color, theme: theme)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Organ FX row

struct OrganControlsRow: View {
    @ObservedObject var engine: AudioEngine
    @EnvironmentObject var themeManager: ThemeManager
    let color: Color

    var body: some View {
        let preset = engine.currentPreset
        let theme  = themeManager.current
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("DISTORTION")
                    .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
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
            .background(theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.panelBorder, lineWidth: 1))

            Spacer(minLength: 12)

            VStack(spacing: 4) {
                Text("SHIMMER")
                    .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
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
            .background(theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.panelBorder, lineWidth: 1))
        }
    }
}

// MARK: - Rhodes controls row

struct RhodesControlsRow: View {
    @ObservedObject var engine: AudioEngine
    let color: Color

    var body: some View {
        let preset = engine.currentPreset
        HStack(spacing: 16) {
            KnobView(label: "TREMOLO", value: preset.tremulantDepth, color: color) { v in
                engine.currentPreset.tremulantDepth = v
            }
            KnobView(label: "CHORUS", value: preset.chorusMix, color: color) { v in
                engine.currentPreset.chorusMix = v
            }
            KnobView(label: "SHIMMER", value: preset.shimmerAmount, color: color) { v in
                engine.setShimmer(v)
            }
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

// MARK: - Texture row (Lo-Fi, Vinyl, B.Tape, Grit, Doubler)

struct TextureRow: View {
    @ObservedObject var engine: AudioEngine
    let color: Color
    let theme: AppTheme

    var body: some View {
        let preset = engine.currentPreset
        VStack(spacing: 4) {
            Text("TEXTURE")
                .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                .foregroundColor(color.opacity(0.6))
                .kerning(2)

            HStack(spacing: 12) {
                KnobView(label: "LO-FI", value: preset.lofiAmount, color: color) { v in
                    engine.setLofi(v)
                }
                KnobView(label: "VINYL", value: preset.vinylAmount, color: color) { v in
                    engine.setVinyl(v)
                }
                KnobView(label: "B.TAPE", value: preset.brokenTape, color: color) { v in
                    engine.setBrokenTape(v)
                }
                KnobView(label: "GRIT", value: preset.gritAmount, color: color) { v in
                    engine.setGrit(v)
                }
                KnobView(label: "DBLR", value: preset.doublerAmount, color: color) { v in
                    engine.setDoubler(v)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }
}

// MARK: - Knob

struct KnobView: View {
    let label: String
    let value: Float
    let color: Color
    let onChange: (Float) -> Void

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var lastDragY: CGFloat = 0

    private let minAngle: Double = -135
    private let maxAngle: Double =  135

    private var isPad: Bool { sizeClass == .regular }

    private var outerSize: CGFloat  { isPad ? 72 : 52 }
    private var trackSize: CGFloat  { isPad ? 62 : 44 }
    private var innerSize: CGFloat  { isPad ? 54 : 38 }
    private var needleLen: CGFloat  { isPad ? 14 : 10 }
    private var needleOff: CGFloat  { isPad ? -17 : -12 }
    private var labelSize: CGFloat  { isPad ? 11 : 9 }

    var body: some View {
        let theme = themeManager.current
        let accent = theme.accent(for: color)

        VStack(spacing: isPad ? 6 : 4) {
            ZStack {
                // Outer glow ring
                Circle()
                    .fill(theme.knobTrackBg)
                    .frame(width: outerSize, height: outerSize)

                // Progress arc
                Circle()
                    .trim(from: 0, to: CGFloat(value))
                    .stroke(accent.opacity(0.85),
                            style: StrokeStyle(lineWidth: isPad ? 4 : 3, lineCap: .round))
                    .frame(width: trackSize, height: trackSize)
                    .rotationEffect(.degrees(-90))

                // Knob body
                Circle()
                    .fill(theme.knobBody)
                    .frame(width: innerSize, height: innerSize)
                    .shadow(color: accent.opacity(0.35), radius: isPad ? 6 : 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accent)
                            .frame(width: isPad ? 4 : 3, height: needleLen)
                            .offset(y: needleOff)
                            .rotationEffect(.degrees(mappedAngle))
                    )
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let delta = Float(lastDragY - v.location.y) * (isPad ? 0.004 : 0.005)
                        lastDragY = v.location.y
                        onChange(max(0, min(1, value + delta)))
                    }
                    .onEnded { _ in lastDragY = 0 }
            )

            Text(label)
                .font(.system(size: labelSize, weight: .semibold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
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

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var lastDragY: CGFloat = 0

    private var isPad: Bool { sizeClass == .regular }
    private var sliderW: CGFloat  { isPad ? 48 : 36 }
    private var sliderH: CGFloat  { isPad ? 88 : 64 }
    private var fillW: CGFloat    { isPad ? 38 : 28 }
    private var labelSize: CGFloat { isPad ? 11 : 9 }

    var body: some View {
        let theme = themeManager.current
        let accent = theme.accent(for: color)

        VStack(spacing: isPad ? 6 : 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.knobTrackBg)
                    .frame(width: sliderW, height: sliderH)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: fillW, height: max(4, CGFloat(value) * (sliderH - 8)))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let delta = Float(lastDragY - v.location.y) * (isPad ? 0.005 : 0.007)
                        lastDragY = v.location.y
                        onChange(max(0.001, min(1, value + delta)))
                    }
                    .onEnded { _ in lastDragY = 0 }
            )

            Text(label)
                .font(.system(size: labelSize, weight: .semibold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .kerning(1.5)
        }
    }
}
