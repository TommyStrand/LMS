import SwiftUI

struct ControlsView: View {
    @ObservedObject var engine: AudioEngine
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        let preset = engine.currentPreset
        let color  = Color(hex: preset.color)
        let theme  = themeManager.current

        // On compact (iPhone) screens the panel is height-limited so it scrolls;
        // on regular (iPad) screens it expands naturally in the side column.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                // Row 1 – FILTER/RESON only for synth
                HStack(spacing: 16) {
                    KnobView(label: "REVERB", value: preset.reverbMix, color: color) { v in
                        engine.setReverb(v)
                    }
                    KnobView(label: "DELAY", value: preset.delayMix, color: color) { v in
                        engine.setDelay(v)
                    }
                    if preset.voiceMode == .synth {
                        KnobView(label: "FILTER", value: preset.filterCutoff / 20000, color: color) { v in
                            engine.currentPreset.filterCutoff = v * 20000
                        }
                        KnobView(label: "RESON", value: preset.filterResonance, color: color) { v in
                            engine.currentPreset.filterResonance = v
                        }
                    }
                }

                // Row 2 – voice-specific controls
                switch preset.voiceMode {
                case .organChurch, .hammondB3:
                    OrganControlsRow(engine: engine, color: color)
                case .rhodes:
                    RhodesControlsRow(engine: engine, color: color)
                case .synth:
                    EnvelopeRow(engine: engine, color: color, theme: theme)
                }

                // Row 3 – Modulation (synth only)
                if preset.voiceMode == .synth {
                    ModulationRow(engine: engine, color: color, theme: theme)
                }

                // Row 4 – Texture (always visible)
                TextureRow(engine: engine, color: color, theme: theme)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        // Limit height on iPhone so controls don't push the play surface out of view
        .frame(maxHeight: sizeClass == .compact ? 300 : .infinity)
    }
}

// MARK: - Modulation row (universal, all voice modes)

struct ModulationRow: View {
    @ObservedObject var engine: AudioEngine
    let color: Color
    let theme: AppTheme

    var body: some View {
        let preset = engine.currentPreset
        VStack(spacing: 4) {
            Text("MODULATION")
                .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                .foregroundColor(color.opacity(0.6))
                .kerning(2)

            HStack(spacing: 24) {
                KnobView(label: "TREM",  value: preset.tremulantDepth, color: color) { v in
                    engine.setTremolo(v)
                }
                KnobView(label: "CHORUS", value: preset.chorusMix,     color: color) { v in
                    engine.setChorus(v)
                }
                KnobView(label: "DRIVE",  value: preset.distortionAmount, color: color) { v in
                    engine.setDistortion(v)
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
                KnobView(label: "DRIVE", value: preset.distortionAmount, color: color) { v in
                    engine.setDistortion(v)
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
                    KnobView(label: "CHORUS", value: preset.chorusMix, color: color) { v in
                        engine.setChorus(v)
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
            KnobView(label: "DRIVE", value: preset.distortionAmount, color: color) { v in
                engine.setDistortion(v)
            }
        }
    }
}

// MARK: - Envelope row (Attack / Decay / Sustain / Release)
// Uses the same KnobView as every other row — compact, consistent, and scrolls
// with the rest of the controls panel on small screens.

struct EnvelopeRow: View {
    @ObservedObject var engine: AudioEngine
    let color: Color
    let theme: AppTheme

    var body: some View {
        let preset = engine.currentPreset
        VStack(spacing: 4) {
            Text("ENVELOPE")
                .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                .foregroundColor(color.opacity(0.6))
                .kerning(2)

            HStack(spacing: 16) {
                KnobView(label: "ATTK", value: preset.attack / 3.0, color: color) { v in
                    engine.currentPreset.attack = v * 3.0
                }
                KnobView(label: "DECAY", value: preset.decay / 2.0, color: color) { v in
                    engine.currentPreset.decay = v * 2.0
                }
                KnobView(label: "SUST", value: preset.sustain, color: color) { v in
                    engine.currentPreset.sustain = v
                }
                KnobView(label: "REL", value: preset.release / 4.0, color: color) { v in
                    engine.currentPreset.release = v * 4.0
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

// MARK: - Texture row

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
                KnobView(label: "S.ECHO", value: preset.spaceEchoAmount, color: color) { v in
                    engine.setSpaceEcho(v)
                }
                KnobView(label: "B.TAPE", value: preset.brokenTape, color: color) { v in
                    engine.setBrokenTape(v)
                }
                KnobView(label: "GRIT", value: preset.gritAmount, color: color) { v in
                    engine.setGrit(v)
                }
            }
            HStack(spacing: 12) {
                KnobView(label: "BLOOM", value: preset.bloomAmount, color: color) { v in
                    engine.setBloom(v)
                }
                KnobView(label: "PHASER", value: preset.phaserAmount, color: color) { v in
                    engine.setPhaser(v)
                }
                KnobView(label: "A.WAH", value: preset.autoWahAmount, color: color) { v in
                    engine.setAutoWah(v)
                }
                KnobView(label: "WAVER", value: preset.modDelayAmount, color: color) { v in
                    engine.setModDelay(v)
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

// MARK: - Knob (4 styles)

struct KnobView: View {
    let label: String
    let value: Float
    let color: Color
    let onChange: (Float) -> Void

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var lastDragY: CGFloat = 0
    @State private var isDragging = false

    private let minAngle: Double = -135
    private let maxAngle: Double =  135

    private var isPad: Bool      { sizeClass == .regular }
    private var outerSize: CGFloat  { isPad ? 72 : 52 }
    private var trackSize: CGFloat  { isPad ? 62 : 44 }
    private var innerSize: CGFloat  { isPad ? 54 : 38 }
    private var needleLen: CGFloat  { isPad ? 14 : 10 }
    private var needleOff: CGFloat  { isPad ? -17 : -12 }
    private var labelSize: CGFloat  { isPad ? 11 : 9 }
    private var faderH: CGFloat     { outerSize * 1.5 }
    private var faderThumbW: CGFloat { isPad ? 32 : 24 }
    private var faderThumbH: CGFloat { isPad ? 18 : 14 }
    private var mappedAngle: Double { Double(value) * (maxAngle - minAngle) + minAngle }

    private var dragSensitivity: Float {
        themeManager.controlStyle == .fader
            ? Float(1.0 / faderH)
            : (isPad ? 0.004 : 0.005)
    }

    var body: some View {
        let theme  = themeManager.current
        let accent = theme.accent(for: color)
        let style  = themeManager.controlStyle

        VStack(spacing: isPad ? 6 : 4) {
            controlGraphic(style: style, theme: theme, accent: accent)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !isDragging { isDragging = true; lastDragY = v.location.y }
                            let delta = Float(lastDragY - v.location.y) * dragSensitivity
                            lastDragY = v.location.y
                            onChange(max(0, min(1, value + delta)))
                        }
                        .onEnded { _ in isDragging = false }
                )

            Text(label)
                .font(.system(size: labelSize, weight: .semibold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .kerning(1.5)
        }
    }

    // MARK: Style dispatch

    @ViewBuilder
    private func controlGraphic(style: ControlStyle, theme: AppTheme, accent: Color) -> some View {
        switch style {
        case .rotary:  rotaryView(theme: theme, accent: accent)
        case .ledRing: ledRingView(accent: accent)
        case .fader:   faderView(theme: theme, accent: accent)
        case .flatArc: flatArcView(accent: accent)
        }
    }

    // MARK: Rotary knob

    @ViewBuilder
    private func rotaryView(theme: AppTheme, accent: Color) -> some View {
        ZStack {
            Circle()
                .fill(theme.knobTrackBg)
                .frame(width: outerSize, height: outerSize)
            Circle()
                .trim(from: 0, to: CGFloat(value))
                .stroke(accent.opacity(0.85),
                        style: StrokeStyle(lineWidth: isPad ? 4 : 3, lineCap: .round))
                .frame(width: trackSize, height: trackSize)
                .rotationEffect(.degrees(-90))
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
        .frame(width: outerSize, height: outerSize)
    }

    // MARK: LED ring (24 dots, 270° arc)

    @ViewBuilder
    private func ledRingView(accent: Color) -> some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let radius = min(cx, cy) * 0.78
            let count  = 24
            let startDeg = 135.0
            let span     = 270.0

            for i in 0..<count {
                let t      = Double(i) / Double(count - 1)
                let angle  = (startDeg + t * span) * .pi / 180
                let dotX   = cx + CGFloat(cos(angle)) * radius
                let dotY   = cy + CGFloat(sin(angle)) * radius
                let isLit  = Float(t) <= value
                let dotR   = size.width * (isLit ? 0.052 : 0.038)
                var dot    = Path()
                dot.addEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR,
                                         width: dotR * 2, height: dotR * 2))
                ctx.fill(dot, with: .color(accent.opacity(isLit ? 1.0 : 0.12)))
            }

            // Faint centre pip
            var pip = Path()
            pip.addEllipse(in: CGRect(x: cx - 2.5, y: cy - 2.5, width: 5, height: 5))
            ctx.fill(pip, with: .color(accent.opacity(0.4)))
        }
        .frame(width: outerSize, height: outerSize)
    }

    // MARK: Vertical fader

    @ViewBuilder
    private func faderView(theme: AppTheme, accent: Color) -> some View {
        let trackW  = CGFloat(6)
        let fillH   = (faderH - faderThumbH) * CGFloat(value) + faderThumbH / 2
        let thumbOff = -((faderH - faderThumbH) * CGFloat(value))

        ZStack(alignment: .bottom) {
            // Track
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.knobTrackBg)
                .frame(width: trackW, height: faderH)

            // Fill (from bottom)
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(0.7))
                .frame(width: trackW, height: max(4, fillH))

            // Thumb
            RoundedRectangle(cornerRadius: isPad ? 5 : 4)
                .fill(theme.knobBody)
                .overlay(
                    RoundedRectangle(cornerRadius: isPad ? 5 : 4)
                        .strokeBorder(accent.opacity(0.85), lineWidth: 1.5)
                )
                .frame(width: faderThumbW, height: faderThumbH)
                .shadow(color: accent.opacity(0.4), radius: 4)
                .offset(y: thumbOff)

            // Centre grip line
            RoundedRectangle(cornerRadius: 1)
                .fill(accent.opacity(0.5))
                .frame(width: faderThumbW * 0.5, height: 2)
                .offset(y: thumbOff)
        }
        .frame(width: faderThumbW, height: faderH)
    }

    // MARK: Flat arc (minimal, no body)

    @ViewBuilder
    private func flatArcView(accent: Color) -> some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let radius   = min(cx, cy) * 0.72
            let lineW    = size.width * 0.09
            let startDeg = 135.0
            let span     = 270.0
            let activeDeg = startDeg + Double(value) * span

            // Background track
            var track = Path()
            track.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                         startAngle: .degrees(startDeg),
                         endAngle:   .degrees(startDeg + span),
                         clockwise: false)
            ctx.stroke(track, with: .color(accent.opacity(0.15)),
                       style: StrokeStyle(lineWidth: lineW, lineCap: .round))

            // Active arc
            if value > 0.01 {
                var active = Path()
                active.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                              startAngle: .degrees(startDeg),
                              endAngle:   .degrees(activeDeg),
                              clockwise: false)
                ctx.stroke(active, with: .color(accent),
                           style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            }

            // End dot
            let dotAngle = activeDeg * .pi / 180
            let dotX = cx + CGFloat(cos(dotAngle)) * radius
            let dotY = cy + CGFloat(sin(dotAngle)) * radius
            let dotR = lineW * 0.75
            var endDot = Path()
            endDot.addEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR,
                                         width: dotR * 2, height: dotR * 2))
            ctx.fill(endDot, with: .color(accent))
        }
        .frame(width: outerSize, height: outerSize)
    }
}

