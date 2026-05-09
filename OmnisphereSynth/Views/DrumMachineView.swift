import SwiftUI

struct DrumMachineView: View {
    @ObservedObject var drum: DrumEngine
    @EnvironmentObject  var themeManager: ThemeManager
    @State private var selectedFeel: DrumFeel = .ride

    var body: some View {
        let theme  = themeManager.current
        let accent = theme.accent(for: Color(hex: "#E07040"))

        GeometryReader { geo in
            VStack(spacing: 0) {
                feelSelector(theme: theme, accent: accent)
                    .padding(.bottom, 6)

                patternStrip(theme: theme, accent: accent)
                    .padding(.bottom, 8)

                HStack(spacing: 16) {
                    beatRing(accent: accent, theme: theme)
                        .frame(width: min(geo.size.width * 0.38, 200),
                               height: min(geo.size.width * 0.38, 200))

                    VStack(spacing: 12) {
                        bpmRow(theme: theme, accent: accent)
                        effectsGrid(theme: theme, accent: accent)
                        Spacer(minLength: 0)
                        playButton(theme: theme, accent: accent)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)

                voiceActivityRow(theme: theme, accent: accent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Feel selector

    private func feelSelector(theme: AppTheme, accent: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DrumFeel.allCases, id: \.self) { feel in
                    let selected = selectedFeel == feel
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedFeel = feel
                            // Select first pattern in the new feel if current is outside it
                            let feelPatterns = DrumPattern.patterns(for: feel)
                            if !feelPatterns.isEmpty {
                                let currentPattern = DrumPattern.all[drum.patternIndex]
                                if currentPattern.feel != feel {
                                    if let idx = DrumPattern.all.firstIndex(where: { $0.feel == feel }) {
                                        drum.patternIndex = idx
                                    }
                                }
                            }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 3) {
                            Text(feel.emoji)
                                .font(.system(size: 16))
                            Text(feel.rawValue.uppercased())
                                .font(.system(size: 8, weight: .bold, design: theme.fontDesign))
                                .kerning(1.2)
                        }
                        .foregroundColor(selected ? theme.appBackground : accent)
                        .frame(width: 52, height: 46)
                        .background(selected ? accent : theme.panelBackground)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                                .strokeBorder(selected ? Color.clear : accent.opacity(0.35), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Pattern strip (filtered by feel)

    private func patternStrip(theme: AppTheme, accent: Color) -> some View {
        let feelPatterns = DrumPattern.patterns(for: selectedFeel)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(feelPatterns.indices, id: \.self) { localIdx in
                    let pattern = feelPatterns[localIdx]
                    let globalIdx = DrumPattern.all.firstIndex(where: { $0.name == pattern.name }) ?? 0
                    let selected  = drum.patternIndex == globalIdx
                    Button {
                        drum.patternIndex = globalIdx
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 3) {
                            Text(pattern.name)
                                .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                            Text("\(pattern.bars)BAR")
                                .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                                .opacity(0.65)
                        }
                        .foregroundColor(selected ? theme.appBackground : accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(selected ? accent : theme.panelBackground)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? Color.clear : accent.opacity(0.35),
                                lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Beat ring

    private func beatRing(accent: Color, theme: AppTheme) -> some View {
        ZStack {
            Circle()
                .stroke(theme.panelBorder, lineWidth: 3)

            Circle()
                .trim(from: 0, to: drum.beatFraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: drum.beatFraction)

            let beats = max(2, DrumPattern.all[drum.patternIndex].bars * 4)
            ForEach(0 ..< beats, id: \.self) { i in
                let angle = Double(i) / Double(beats) * 2 * .pi - .pi / 2
                let isBar = i % 4 == 0
                Circle()
                    .fill(isBar ? accent.opacity(0.8) : theme.secondaryText.opacity(0.25))
                    .frame(width: isBar ? 6 : 3, height: isBar ? 6 : 3)
                    .offset(x: cos(angle) * 46, y: sin(angle) * 46)
            }

            VStack(spacing: 2) {
                Image(systemName: drum.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundColor(accent)
                Text("\(Int(drum.bpm)) BPM")
                    .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText)
            }
            .onTapGesture {
                drum.togglePlay()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - BPM row

    private func bpmRow(theme: AppTheme, accent: Color) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("BPM")
                    .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText)
                    .kerning(1.5)
                Spacer()
                Text("\(Int(drum.bpm))")
                    .font(.system(size: 22, weight: .thin, design: theme.fontDesign))
                    .foregroundColor(accent)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)

            Slider(value: $drum.bpm, in: 50...180, step: 1)
                .accentColor(accent)
                .padding(.horizontal, 4)

            HStack {
                Text("50")
                    .font(.system(size: 8, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                Spacer()
                Text("180")
                    .font(.system(size: 8, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.panelBorder, lineWidth: 1)
        )
    }

    // MARK: - Effects grid

    private func effectsGrid(theme: AppTheme, accent: Color) -> some View {
        HStack(spacing: 12) {
            effectKnob(label: "DELAY",   value: $drum.delayMix, accent: accent, theme: theme)
            effectKnob(label: "SHIMMER", value: $drum.shimmer,  accent: accent, theme: theme)
            effectKnob(label: "DIRT",    value: $drum.grit,     accent: accent, theme: theme)
        }
    }

    private func effectKnob(label: String,
                            value: Binding<Float>,
                            accent: Color,
                            theme: AppTheme) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .trim(from: 0.15, to: 0.85)
                    .stroke(theme.panelBorder, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(90 + 180 * 0.15))
                    .frame(width: 52, height: 52)

                let filled = 0.15 + (0.85 - 0.15) * Double(value.wrappedValue)
                Circle()
                    .trim(from: 0.15, to: filled)
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(90 + 180 * 0.15))
                    .frame(width: 52, height: 52)
                    .animation(.easeOut(duration: 0.08), value: value.wrappedValue)

                Text(String(format: "%.0f", value.wrappedValue * 100))
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let delta = Float(-drag.translation.height / 120)
                        value.wrappedValue = max(0, min(1, value.wrappedValue + delta))
                    }
            )

            Text(label)
                .font(.system(size: 8, weight: .bold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .kerning(1.5)
        }
    }

    // MARK: - Play button

    private func playButton(theme: AppTheme, accent: Color) -> some View {
        Button {
            drum.togglePlay()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: drum.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                Text(drum.isPlaying ? "STOP" : "PLAY")
                    .font(.system(size: 13, weight: .bold, design: theme.fontDesign))
                    .kerning(2)
            }
            .foregroundColor(drum.isPlaying ? theme.appBackground : accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(drum.isPlaying ? accent : theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(drum.isPlaying ? Color.clear : accent.opacity(0.5), lineWidth: 1.5)
            )
        }
    }

    // MARK: - Voice activity row

    private func voiceActivityRow(theme: AppTheme, accent: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(DrumVoiceID.allCases, id: \.self) { v in
                let active = isVoiceActive(v)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active ? accent : theme.panelBorder)
                        .frame(width: 28, height: 20)
                        .animation(.easeOut(duration: 0.06), value: active)
                    Text(v.label)
                        .font(.system(size: 6, weight: .bold, design: theme.fontDesign))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 28)
                }
            }
        }
    }

    private func isVoiceActive(_ voice: DrumVoiceID) -> Bool {
        guard drum.isPlaying else { return false }
        let loopTicks   = Double(DrumPattern.all[drum.patternIndex].loopTicks)
        let currentTick = drum.beatFraction * loopTicks
        let windowTicks = Double(DrumPattern.all[drum.patternIndex].ticksPerBeat) * 0.35
        return DrumPattern.all[drum.patternIndex].hits.contains { hit in
            hit.voice == voice && abs(Double(hit.tick) - currentTick) < windowTicks
        }
    }
}
