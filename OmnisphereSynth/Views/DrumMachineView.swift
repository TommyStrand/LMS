import SwiftUI

struct DrumMachineView: View {
    @Bindable var drum: DrumEngine        // @Bindable: this view binds $drum.bpm / knobs
    var favorites: FavoritesStore
    @Environment(ThemeManager.self) var themeManager

    @State private var showFavorites = false

    private let accent = Color(hex: "#E07040")

    var body: some View {
        let theme   = themeManager.current
        let ac      = theme.accent(for: accent)
        let pattern = DrumPattern.all[drum.patternIndex]

        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                patternCard(pattern: pattern, theme: theme, ac: ac)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                actionRow(theme: theme, ac: ac)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                bpmRow(pattern: pattern, theme: theme, ac: ac)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                stepSequencerPanel(pattern: pattern, theme: theme, ac: ac)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                effectsGrid(theme: theme, ac: ac)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                favoritesButton(theme: theme, ac: ac)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesSheet(drum: drum, favorites: favorites,
                           theme: themeManager.current,
                           ac: themeManager.current.accent(for: accent))
        }
    }

    // MARK: - Pattern card

    private func patternCard(pattern: DrumPattern, theme: AppTheme, ac: Color) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pattern.name)
                    .font(.system(size: 15, weight: .semibold, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(pattern.feel.emoji) \(pattern.feel.rawValue.uppercased())")
                        .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                        .foregroundColor(ac)
                        .kerning(1.2)
                    Text("·")
                        .foregroundColor(theme.secondaryText.opacity(0.4))
                    Text("\(pattern.bars) BAR")
                        .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                        .foregroundColor(theme.secondaryText)
                        .kerning(1.2)
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) { favorites.toggle(pattern.name) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: favorites.contains(pattern.name) ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundColor(favorites.contains(pattern.name) ? .red : theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    // MARK: - Action row

    private func actionRow(theme: AppTheme, ac: Color) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.25)) { drum.randomize() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Label("RANDOM", systemImage: "shuffle")
                    .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                    .kerning(1.5)
                    .foregroundColor(ac)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(theme.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(ac.opacity(0.5), lineWidth: 1.5))
            }

            Button {
                drum.togglePlay()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Label(drum.isPlaying ? "STOP" : "PLAY",
                      systemImage: drum.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                    .kerning(1.5)
                    .foregroundColor(drum.isPlaying ? theme.appBackground : ac)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(drum.isPlaying ? ac : theme.panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(drum.isPlaying ? Color.clear : ac.opacity(0.5), lineWidth: 1.5))
            }
        }
    }

    // MARK: - BPM row (with 2-bar beat strip)

    private func bpmRow(pattern: DrumPattern, theme: AppTheme, ac: Color) -> some View {
        let totalSteps   = 32
        let currentStep  = drum.isPlaying
            ? Int(drum.beatFraction * Double(totalSteps)) % totalSteps
            : -1
        let allHits      = drum.customHits ?? pattern.hits
        let ticksPerStep = Int(pattern.ticksPerBeat) / 4

        return VStack(spacing: 6) {
            HStack {
                Text("BPM")
                    .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText)
                    .kerning(1.5)
                Spacer()
                Text("\(Int(drum.bpm))")
                    .font(.system(size: 22, weight: .thin, design: theme.fontDesign))
                    .foregroundColor(ac)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)

            BeatStripView(totalSteps: totalSteps, currentStep: currentStep,
                          allHits: allHits, ticksPerStep: ticksPerStep, ac: ac, theme: theme)
                .frame(height: 20)
                .padding(.horizontal, 4)

            Slider(value: $drum.bpm, in: 50...180, step: 1)
                .accentColor(ac)
                .padding(.horizontal, 4)

            HStack {
                Text("50").font(.system(size: 8, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                Spacer()
                Text("180").font(.system(size: 8, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    // MARK: - Step Sequencer (ReBirth RB-338 style)

    private func stepSequencerPanel(pattern: DrumPattern, theme: AppTheme, ac: Color) -> some View {
        let totalSteps  = 32
        let currentStep = drum.isPlaying
            ? Int(drum.beatFraction * Double(totalSteps)) % totalSteps
            : -1
        let allActive   = Dictionary(uniqueKeysWithValues: DrumVoiceID.allCases.map { v in
            (v, drum.activeSteps(for: v))
        })

        return VStack(spacing: 0) {
            // Header
            HStack {
                Text("SEQUENCER")
                    .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText)
                    .kerning(1.5)
                Spacer()
                Button {
                    drum.resetPattern()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text("RESET")
                        .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                        .foregroundColor(ac.opacity(0.7))
                        .kerning(1.2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Bar column headers
            HStack(spacing: 0) {
                Color.clear.frame(width: 40)
                Text("BAR 1")
                    .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText.opacity(0.4))
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 9)
                Text("BAR 2")
                    .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            // One row per drum voice
            VStack(spacing: 3) {
                ForEach(DrumVoiceID.allCases, id: \.self) { voice in
                    sequencerRow(voice: voice,
                                 activeSteps: allActive[voice] ?? [],
                                 currentStep: currentStep, ac: ac, theme: theme)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    private func sequencerRow(voice: DrumVoiceID, activeSteps: Set<Int>, currentStep: Int,
                               ac: Color, theme: AppTheme) -> some View {
        HStack(spacing: 0) {
            Text(voice.label)
                .font(.system(size: 6, weight: .bold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 40, alignment: .leading)

            // Bar 1 — steps 0…15
            HStack(spacing: 1) {
                ForEach(0..<16, id: \.self) { step in
                    stepCell(voice: voice, step: step, activeSteps: activeSteps,
                             currentStep: currentStep, ac: ac, theme: theme)
                }
            }
            .frame(maxWidth: .infinity)

            // Bar divider
            Rectangle()
                .fill(theme.secondaryText.opacity(0.2))
                .frame(width: 1)
                .padding(.horizontal, 4)

            // Bar 2 — steps 16…31
            HStack(spacing: 1) {
                ForEach(16..<32, id: \.self) { step in
                    stepCell(voice: voice, step: step, activeSteps: activeSteps,
                             currentStep: currentStep, ac: ac, theme: theme)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stepCell(voice: DrumVoiceID, step: Int, activeSteps: Set<Int>,
                           currentStep: Int, ac: Color, theme: AppTheme) -> some View {
        let isActive  = activeSteps.contains(step)
        let isCurrent = step == currentStep
        let isBeat    = step % 4 == 0   // quarter-note boundary — slightly brighter background

        return RoundedRectangle(cornerRadius: 2)
            .fill(
                isActive  ? ac :
                isBeat    ? theme.secondaryText.opacity(0.14) :
                            theme.panelBorder.opacity(0.45)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isCurrent ? Color.white.opacity(0.9) : Color.clear,
                                  lineWidth: 1.5)
            )
            .frame(height: 18)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.08)) {
                    drum.toggleStep(voice: voice, step: step)
                }
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
    }

    // MARK: - Effects grid

    private func effectsGrid(theme: AppTheme, ac: Color) -> some View {
        HStack(spacing: 0) {
            DrumKnob(label: "VOL",     value: $drum.masterVolume, ac: ac, theme: theme)
            DrumKnob(label: "DELAY",   value: $drum.delayMix,     ac: ac, theme: theme)
            DrumKnob(label: "SHIMMER", value: $drum.shimmer,      ac: ac, theme: theme)
            DrumKnob(label: "DIRT",    value: $drum.grit,         ac: ac, theme: theme)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    // MARK: - Favorites entry

    private func favoritesButton(theme: AppTheme, ac: Color) -> some View {
        Button { showFavorites = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(0.85))
                Text("FAVORITES")
                    .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                    .kerning(1.5)
                    .foregroundColor(theme.secondaryText)
                if !favorites.names.isEmpty {
                    Text("\(favorites.names.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Circle())
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.panelBorder, lineWidth: 1))
        }
    }
}

// MARK: - 2-bar beat strip

private struct BeatStripView: View {
    let totalSteps:   Int
    let currentStep:  Int
    let allHits:      [DrumHit]
    let ticksPerStep: Int
    let ac:    Color
    let theme: AppTheme

    private var stepsWithHits: Set<Int> {
        Set(allHits.map { Int($0.tick) / ticksPerStep })
    }

    var body: some View {
        GeometryReader { geo in
            let barGap:  CGFloat = 6
            let cellGap: CGFloat = 1
            let totalGapWidth = CGFloat(totalSteps - 1) * cellGap + (barGap - cellGap)
            let cellW = (geo.size.width - totalGapWidth) / CGFloat(totalSteps)
            let hits  = stepsWithHits

            HStack(spacing: 0) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    if step == totalSteps / 2 {
                        Spacer().frame(width: barGap - cellGap)
                    } else if step > 0 {
                        Spacer().frame(width: cellGap)
                    }

                    let isCurrent = step == currentStep
                    let hasHit   = hits.contains(step)
                    let isBeat   = step % 4 == 0

                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                isCurrent ? ac :
                                hasHit    ? ac.opacity(0.45) :
                                isBeat    ? theme.secondaryText.opacity(0.2) :
                                            theme.panelBorder.opacity(0.5)
                            )
                            .frame(width: cellW,
                                   height: isBeat ? geo.size.height : geo.size.height * 0.6)

                        if isCurrent {
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                                .frame(width: cellW, height: geo.size.height)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Knob (drag-to-adjust, captures start value per gesture to avoid drift)

private struct DrumKnob: View {
    let label: String
    @Binding var value: Float
    let ac:    Color
    let theme: AppTheme

    private let knobSize: CGFloat = 70
    @State private var dragStartValue: Float = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .trim(from: 0.15, to: 0.85)
                    .stroke(theme.panelBorder, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(90 + 180 * 0.15))
                    .frame(width: knobSize, height: knobSize)

                let filled = 0.15 + (0.85 - 0.15) * Double(value)
                Circle()
                    .trim(from: 0.15, to: filled)
                    .stroke(ac, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(90 + 180 * 0.15))
                    .frame(width: knobSize, height: knobSize)
                    .animation(.easeOut(duration: 0.08), value: value)

                Text(String(format: "%.0f", value * 100))
                    .font(.system(size: 14, weight: .semibold, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                        }
                        let delta = Float(-drag.translation.height / 240)
                        value = max(0, min(1, dragStartValue + delta))
                    }
                    .onEnded { _ in isDragging = false }
            )

            Text(label)
                .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Favorites sheet

private struct FavoritesSheet: View {
    var drum:      DrumEngine
    var favorites: FavoritesStore
    let theme: AppTheme
    let ac:    Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if favorites.patterns.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "heart")
                            .font(.system(size: 44))
                            .foregroundColor(theme.secondaryText.opacity(0.3))
                        Text("No favorites yet")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        Text("Tap ♥ on any pattern to save it here.")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.appBackground.ignoresSafeArea())
                } else {
                    List {
                        ForEach(favorites.patterns, id: \.name) { pattern in
                            let isCurrent = DrumPattern.all.firstIndex(where: { $0.name == pattern.name }) == drum.patternIndex
                            Button {
                                if let idx = DrumPattern.all.firstIndex(where: { $0.name == pattern.name }) {
                                    drum.patternIndex = idx
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(pattern.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(theme.primaryText)
                                        Text("\(pattern.feel.emoji) \(pattern.feel.rawValue)  ·  \(pattern.bars) bar")
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.secondaryText)
                                    }
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(ac)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    favorites.toggle(pattern.name)
                                } label: {
                                    Label("Remove", systemImage: "heart.slash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(ac)
                }
            }
        }
    }
}
