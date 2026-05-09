import SwiftUI

struct ContentView: View {
    @StateObject private var engine       = AudioEngine()
    @StateObject private var themeManager = ThemeManager()
    @State private var selectedPresetIndex = 0
    @State private var showControls  = true
    @State private var showSettings  = false

    var currentPreset: SynthPreset { SynthPreset.presets[selectedPresetIndex] }

    var body: some View {
        let theme = themeManager.current
        GeometryReader { geo in
            ZStack {
                theme.appBackground.ignoresSafeArea()

                // Scanline overlay (Radar theme)
                if theme.scanlines {
                    ScanlinesView().ignoresSafeArea().allowsHitTesting(false)
                }

                if geo.size.width > 680 {
                    ipadLayout(theme: theme, geo: geo)
                } else {
                    iphoneLayout(theme: theme)
                }
            }
        }
        .environmentObject(themeManager)
        .preferredColorScheme(themeManager.current.colorScheme)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(themeManager)
        }
    }

    // MARK: - Play surface helper

    @ViewBuilder
    private func playSurface(preset: SynthPreset) -> some View {
        if themeManager.playMode == .keyboard {
            PianoKeyboardView(engine: engine, preset: preset)
        } else {
            XYPadView(engine: engine, preset: preset)
        }
    }

    // MARK: - iPhone layout

    private func iphoneLayout(theme: AppTheme) -> some View {
        VStack(spacing: 0) {
            header(theme: theme)

            PresetSelectorView(selectedIndex: $selectedPresetIndex) { preset in
                engine.applyPreset(preset)
            }
            .padding(.top, 8)

            playSurface(preset: currentPreset)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(maxHeight: .infinity)

            if showControls {
                ControlsView(engine: engine)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer(minLength: 6)
        }
    }

    // MARK: - iPad layout (side-by-side)

    private func ipadLayout(theme: AppTheme, geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            header(theme: theme)

            HStack(alignment: .top, spacing: 0) {
                // Left panel: presets + controls
                VStack(spacing: 10) {
                    PresetSelectorView(selectedIndex: $selectedPresetIndex) { preset in
                        engine.applyPreset(preset)
                    }

                    if showControls {
                        ControlsView(engine: engine)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width * 0.38)
                .padding(.leading, 16)
                .padding(.top, 10)

                // Right panel: play surface
                playSurface(preset: currentPreset)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Header

    private func header(theme: AppTheme) -> some View {
        let accent = theme.accent(for: Color(hex: currentPreset.color))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SUPERNOVA PAD")
                    .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(accent.opacity(0.9))
                    .kerning(3)
                Text("Touch Synthesizer")
                    .font(.system(size: 18, weight: .thin, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText)
            }

            Spacer()

            // Transpose controls
            HStack(spacing: 0) {
                Button {
                    if themeManager.transposeOctave > -3 {
                        themeManager.transposeOctave -= 1
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 30, height: 30)
                }

                Text(themeManager.transposeOctave == 0
                     ? "OCT"
                     : (themeManager.transposeOctave > 0
                        ? "+\(themeManager.transposeOctave)"
                        : "\(themeManager.transposeOctave)"))
                    .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                    .foregroundColor(themeManager.transposeOctave == 0
                                     ? theme.secondaryText
                                     : accent)
                    .frame(width: 28)

                Button {
                    if themeManager.transposeOctave < 3 {
                        themeManager.transposeOctave += 1
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 30, height: 30)
                }
            }
            .background(theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                    .strokeBorder(theme.panelBorder, lineWidth: 1)
            )

            // Voice indicators
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(i < engine.voices.count ? accent : theme.primaryText.opacity(0.12))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.1), value: engine.voices.count)
                }
            }

            // Play mode toggle
            iconButton(systemName: themeManager.playMode == .grid ? "square.grid.3x3" : "pianokeys",
                       active: false, theme: theme) {
                withAnimation(.spring(response: 0.3)) {
                    themeManager.selectPlayMode(themeManager.playMode == .grid ? .keyboard : .grid)
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }

            // Controls toggle
            iconButton(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle",
                       active: showControls, theme: theme) {
                withAnimation(.spring(response: 0.3)) { showControls.toggle() }
            }

            // Settings
            iconButton(systemName: "gearshape", active: false, theme: theme) {
                showSettings = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func iconButton(systemName: String, active: Bool, theme: AppTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundColor(active
                    ? theme.accent(for: Color(hex: currentPreset.color))
                    : theme.secondaryText)
                .frame(width: 36, height: 36)
                .background(theme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                        .strokeBorder(theme.panelBorder, lineWidth: 1)
                )
        }
    }
}

// MARK: - Scanlines

struct ScanlinesView: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                let r = CGRect(x: 0, y: y, width: size.width, height: 1)
                ctx.fill(Path(r), with: .color(.black.opacity(0.18)))
                y += 3
            }
        }
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
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview { ContentView() }
