import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer

struct ContentView: View {
    // Plain property initialisers: SwiftUI evaluates a @StateObject's wrapped
    // value exactly once and discards re-inits. Allocating these objects eagerly
    // in a custom init() instead spins up a new AudioEngine (AVAudioSession +
    // AVAudioEngine + AVAudioSourceNode) and MIDIController (CoreMIDI client/port)
    // on every view re-init, all of which SwiftUI then throws away — churning
    // mach-port/dispatch objects and risking use-after-free crashes.
    @StateObject private var engine       = AudioEngine()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var midi         = MIDIController()
    @StateObject private var drum      = DrumEngine()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var recorder  = AudioRecorder()
    @State private var selectedPresetIndex = 0
    @State private var showControls    = true
    @State private var showSettings    = false
    @State private var midiActivityLit = false
    @State private var showDrumMachine = false
    @State private var showShareSheet  = false
    @State private var recBlink        = false

    // Initialise NowPlayingManager once so remote commands are registered early
    private let nowPlaying = NowPlayingManager.shared

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
        .onAppear { midi.attach(to: engine) }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(themeManager)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { recorder.exportURL = nil }) {
            if let url = recorder.exportURL {
                ShareSheet(url: url)
            }
        }
        .onChange(of: midi.activityPulse) { _ in
            midiActivityLit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                midiActivityLit = false
            }
        }
        .onChange(of: recorder.exportURL) { url in
            if url != nil { showShareSheet = true }
        }
        .onChange(of: recorder.isRecording) { recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    recBlink = true
                }
            } else {
                withAnimation(.default) { recBlink = false }
            }
        }
        // MARK: - AirPlay 2 / Now Playing updates
        .onChange(of: selectedPresetIndex) { idx in
            nowPlaying.update(presetName: SynthPreset.presets[idx].name,
                              isLiveInstrument: true, isPlaying: false)
        }
        .onChange(of: showDrumMachine) { drumActive in
            let title = drumActive
                ? DrumPattern.all[drum.patternIndex].name + " — Drum"
                : SynthPreset.presets[selectedPresetIndex].name
            nowPlaying.update(presetName: title, isLiveInstrument: true,
                              isPlaying: drumActive && drum.isPlaying)
        }
        .onChange(of: drum.patternIndex) { idx in
            guard showDrumMachine else { return }
            nowPlaying.update(presetName: DrumPattern.all[idx].name + " — Drum",
                              isLiveInstrument: true, isPlaying: drum.isPlaying)
        }
        .onChange(of: drum.isPlaying) { playing in
            nowPlaying.setPlaybackState(playing)
        }
        // Remote commands from lock screen / AirPlay device / Control Centre
        .onReceive(NotificationCenter.default.publisher(for: .remotePlay)) { _ in
            if showDrumMachine && !drum.isPlaying { drum.play() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePause)) { _ in
            if drum.isPlaying { drum.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteToggle)) { _ in
            if showDrumMachine { drum.togglePlay() }
        }
        .onAppear {
            nowPlaying.update(presetName: SynthPreset.presets[selectedPresetIndex].name,
                              isLiveInstrument: true, isPlaying: false)
        }
    }

    // MARK: - Play surface helper

    @ViewBuilder
    private func playSurface(preset: SynthPreset) -> some View {
        if showDrumMachine {
            DrumMachineView(drum: drum, favorites: favorites)
        } else if themeManager.playMode == .keyboard {
            PianoKeyboardView(engine: engine, preset: preset)
        } else {
            // .grid and .glissando both use the XY pad; glissando changes touch behaviour
            XYPadView(engine: engine, preset: preset)
        }
    }

    // MARK: - iPhone layout

    private func iphoneLayout(theme: AppTheme) -> some View {
        VStack(spacing: 0) {
            header(theme: theme)

            PresetSelectorView(selectedIndex: $selectedPresetIndex, engine: engine) { preset in
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
                    PresetSelectorView(selectedIndex: $selectedPresetIndex, engine: engine) { preset in
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

            // MIDI indicator
            if midi.isConnected {
                HStack(spacing: 5) {
                    Circle()
                        .fill(accent.opacity(midiActivityLit ? 1.0 : 0.3))
                        .frame(width: 6, height: 6)
                        .animation(.easeOut(duration: 0.2), value: midiActivityLit)
                    Text(String((midi.primaryDeviceName ?? "MIDI").prefix(12)))
                        .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                        .strokeBorder(theme.panelBorder, lineWidth: 1)
                )
            }

            // Drum machine toggle
            iconButton(systemName: "music.quarternote.3",
                       active: showDrumMachine, theme: theme) {
                withAnimation(.spring(response: 0.3)) { showDrumMachine.toggle() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }

            // Play mode toggle (hidden while drum machine is active)
            if !showDrumMachine {
                iconButton(systemName: themeManager.playMode.icon, active: false, theme: theme) {
                    withAnimation(.spring(response: 0.3)) {
                        let modes = PlayMode.allCases
                        let idx   = modes.firstIndex(of: themeManager.playMode) ?? 0
                        themeManager.selectPlayMode(modes[(idx + 1) % modes.count])
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }

            // Controls toggle
            iconButton(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle",
                       active: showControls, theme: theme) {
                withAnimation(.spring(response: 0.3)) { showControls.toggle() }
            }

            // Record / export
            recordButton(theme: theme, accent: accent)

            // AirPlay output picker
            AirPlayButton(tintColor: UIColor(theme.secondaryText))
                .frame(width: 36, height: 36)
                .background(theme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                        .strokeBorder(theme.panelBorder, lineWidth: 1)
                )

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

    @ViewBuilder
    private func recordButton(theme: AppTheme, accent: Color) -> some View {
        let recColor = Color.red
        Button {
            if recorder.isRecording {
                recorder.stopRecording()
            } else {
                recorder.startRecording(synthEngine: engine.avEngine, drumEngine: drum.avEngine)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                    .fill(theme.panelBackground)
                RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                    .strokeBorder(recorder.isRecording
                                  ? recColor.opacity(recBlink ? 0.9 : 0.3)
                                  : theme.panelBorder, lineWidth: 1)
                if recorder.isExporting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(theme.secondaryText)
                } else {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 17))
                        .foregroundColor(recorder.isRecording
                                         ? recColor.opacity(recBlink ? 1.0 : 0.5)
                                         : theme.secondaryText)
                }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(recorder.isExporting)
    }
}

// MARK: - AirPlay route picker (wraps AVRoutePickerView for SwiftUI)

struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tintColor
        picker.activeTintColor = tintColor
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = tintColor
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uivc: UIActivityViewController, context: Context) {}
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
