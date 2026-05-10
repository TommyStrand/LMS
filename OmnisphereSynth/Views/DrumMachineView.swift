import SwiftUI

struct DrumMachineView: View {
    @ObservedObject var drum:      DrumEngine
    @ObservedObject var favorites: FavoritesStore
    @EnvironmentObject var themeManager: ThemeManager

    @State private var showFavorites = false

    private let accent = Color(hex: "#E07040")

    var body: some View {
        let theme   = themeManager.current
        let ac      = theme.accent(for: accent)
        let pattern = DrumPattern.all[drum.patternIndex]

        VStack(spacing: 0) {
            patternCard(pattern: pattern, theme: theme, ac: ac)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            actionRow(theme: theme, ac: ac)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            bpmRow(theme: theme, ac: ac)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            effectsGrid(theme: theme, ac: ac)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Spacer(minLength: 0)

            voiceActivityRow(pattern: pattern, theme: theme, ac: ac)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            favoritesButton(theme: theme, ac: ac)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .padding(.top, 8)
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

    // MARK: - BPM row

    private func bpmRow(theme: AppTheme, ac: Color) -> some View {
        VStack(spacing: 6) {
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

    // MARK: - Effects grid (VOL + DELAY + SHIMMER + DIRT — full width, larger knobs)

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

    private func effectKnob(label: String, value: Binding<Float>,
                             ac: Color, theme: AppTheme) -> some View {
        EmptyView()  // replaced by DrumKnob struct below
    }

    // MARK: - Voice activity

    private func voiceActivityRow(pattern: DrumPattern, theme: AppTheme, ac: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(DrumVoiceID.allCases, id: \.self) { v in
                let active = isVoiceActive(v, in: pattern)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active ? ac : theme.panelBorder)
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

    private func isVoiceActive(_ voice: DrumVoiceID, in pattern: DrumPattern) -> Bool {
        guard drum.isPlaying else { return false }
        let currentTick = drum.beatFraction * Double(pattern.loopTicks)
        let window      = Double(pattern.ticksPerBeat) * 0.35
        return pattern.hits.contains { abs(Double($0.tick) - currentTick) < window && $0.voice == voice }
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
                        // 240 px = full 0–1 range, so small touches make small changes
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
    @ObservedObject var drum:      DrumEngine
    @ObservedObject var favorites: FavoritesStore
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
