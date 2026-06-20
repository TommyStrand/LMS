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
    @StateObject private var looper    = LooperEngine()
    @State private var selectedPresetIndex = 0
    @State private var showControls    = true
    @State private var showSettings    = false
    @State private var midiActivityLit = false
    @State private var showDrumMachine = false
    @State private var showShareSheet  = false
    @State private var recBlink        = false
    @State private var showBlob        = false   // blob background visualizer

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
        .onAppear {
            midi.attach(to: engine)
            Diagnostics.shared.startSampling()   // drives the always-on header meter
            looper.audioEngine = engine
            engine.looper      = looper
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine).environmentObject(themeManager)
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
        let theme  = themeManager.current
        let accent = theme.accent(for: Color(hex: preset.color))

        if showDrumMachine {
            DrumMachineView(drum: drum, favorites: favorites)
        } else {
            ZStack {
                // Optional blob background — sits behind the play surface and
                // reacts to the live waveform without blocking touch input.
                if showBlob {
                    BlobVisualizerView(engine: engine, color: accent, theme: theme)
                        .allowsHitTesting(false)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 1.4))
                }

                switch themeManager.playMode {
                case .keyboard:
                    PianoKeyboardView(engine: engine, preset: preset)
                case .isomorphic:
                    IsomorphicPadView(engine: engine, preset: preset)
                default:
                    // .grid and .glissando both use the XY pad; glissando changes
                    // touch behaviour inside the view.
                    XYPadView(engine: engine, preset: preset)
                }
            }
        }
    }

    // MARK: - iPhone layout

    private func iphoneLayout(theme: AppTheme) -> some View {
        let accent = theme.accent(for: Color(hex: currentPreset.color))
        return VStack(spacing: 0) {
            header(theme: theme, compact: true)

            PresetSelectorView(selectedIndex: $selectedPresetIndex, engine: engine) { preset in
                engine.applyPreset(preset)
            }
            .padding(.top, 8)

            playSurface(preset: currentPreset)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(maxHeight: .infinity)

            // Looper strip — always visible so recording can start instantly
            LooperView(looper: looper, theme: theme, accent: accent)
                .transition(.move(edge: .bottom).combined(with: .opacity))

            if showControls {
                ControlsView(engine: engine)
                    .padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer(minLength: 6)
        }
    }

    // MARK: - iPad layout (side-by-side)

    private func ipadLayout(theme: AppTheme, geo: GeometryProxy) -> some View {
        let accent = theme.accent(for: Color(hex: currentPreset.color))
        return VStack(spacing: 0) {
            header(theme: theme, compact: false)

            HStack(alignment: .top, spacing: 0) {
                // Left panel: presets + controls
                VStack(spacing: 10) {
                    PresetSelectorView(selectedIndex: $selectedPresetIndex, engine: engine) { preset in
                        engine.applyPreset(preset)
                    }

                    LooperView(looper: looper, theme: theme, accent: accent)

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
    //
    // Organised into three labelled clusters separated by dividers rather than a
    // single row of multi-purpose icons:
    //   • Transport  — transpose, play mode, drum machine
    //   • Status     — voice activity, MIDI, live CPU/RAM meter
    //   • System     — controls, record, AirPlay, settings
    // `compact` (iPhone) tightens spacing, drops the dividers and the brand
    // subtitle, and keeps the cycling play-mode button; expanded (iPad) uses the
    // extra width for an explicit segmented play-mode picker and the full meter.

    private func header(theme: AppTheme, compact: Bool) -> some View {
        let accent = theme.accent(for: Color(hex: currentPreset.color))
        return HStack(spacing: compact ? 8 : 14) {
            brandView(theme: theme, accent: accent, compact: compact)
            Spacer(minLength: 8)
            transportGroup(theme: theme, accent: accent, compact: compact)
            if !compact { groupDivider(theme: theme) }
            statusGroup(theme: theme, accent: accent, compact: compact)
            if !compact { groupDivider(theme: theme) }
            systemGroup(theme: theme, accent: accent)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: Header clusters

    private func transportGroup(theme: AppTheme, accent: Color, compact: Bool) -> some View {
        HStack(spacing: 8) {
            transposeControls(theme: theme, accent: accent)
            modeToggle(theme: theme, accent: accent, compact: compact)
            if !showDrumMachine {
                playModeControl(theme: theme, accent: accent, compact: compact)
            }
        }
    }

    private func statusGroup(theme: AppTheme, accent: Color, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if !compact { voiceDots(theme: theme, accent: accent) }
            if midi.isConnected { midiChip(theme: theme, accent: accent) }
            HeaderMeter(compact: compact, theme: theme)
        }
    }

    private func systemGroup(theme: AppTheme, accent: Color) -> some View {
        HStack(spacing: 8) {
            iconButton(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle",
                       active: showControls, theme: theme) {
                withAnimation(.spring(response: 0.3)) { showControls.toggle() }
            }
            // Blob visualizer toggle
            iconButton(systemName: "waveform.circle", active: showBlob, theme: theme) {
                withAnimation(.spring(response: 0.4)) { showBlob.toggle() }
            }
            recordButton(theme: theme, accent: accent)
            AirPlayButton(tintColor: UIColor(theme.secondaryText))
                .frame(width: 36, height: 36)
                .background(theme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                    .strokeBorder(theme.panelBorder, lineWidth: 1))
            iconButton(systemName: "gearshape", active: false, theme: theme) {
                showSettings = true
            }
        }
    }

    // MARK: Header pieces

    private func brandView(theme: AppTheme, accent: Color, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SUPERNOVA PAD")
                .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                .foregroundColor(accent.opacity(0.9))
                .kerning(compact ? 1.5 : 3)
            if !compact {
                Text("Touch Synthesizer")
                    .font(.system(size: 18, weight: .thin, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText)
            }
        }
        .lineLimit(1)
    }

    private func transposeControls(theme: AppTheme, accent: Color) -> some View {
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
                .foregroundColor(themeManager.transposeOctave == 0 ? theme.secondaryText : accent)
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
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func playModeControl(theme: AppTheme, accent: Color, compact: Bool) -> some View {
        if compact {
            // Compact: single cycling button (no room for a segmented control).
            iconButton(systemName: themeManager.playMode.icon, active: false, theme: theme) {
                withAnimation(.spring(response: 0.3)) {
                    let modes = PlayMode.allCases
                    let idx   = modes.firstIndex(of: themeManager.playMode) ?? 0
                    themeManager.selectPlayMode(modes[(idx + 1) % modes.count])
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } else {
            // Expanded: explicit segmented picker — no more guessing what the
            // cycling icon will switch to.
            HStack(spacing: 2) {
                ForEach(PlayMode.allCases) { mode in
                    let isOn = themeManager.playMode == mode
                    Button {
                        withAnimation(.spring(response: 0.3)) { themeManager.selectPlayMode(mode) }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isOn ? .white : theme.secondaryText)
                            .frame(width: 36, height: 30)
                            .background(isOn ? accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 2))
                    }
                }
            }
            .padding(3)
            .background(theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
                .strokeBorder(theme.panelBorder, lineWidth: 1))
        }
    }

    /// Top-level surface switch: PLAY (instrument) vs DRUMS. Always visible — both
    /// segments are shown at all times, so returning from the drum machine to the
    /// play grid is an obvious one-tap action rather than re-tapping a toggle.
    private func modeToggle(theme: AppTheme, accent: Color, compact: Bool) -> some View {
        HStack(spacing: 2) {
            modeSegment(icon: "pianokeys", label: "PLAY", active: !showDrumMachine,
                        theme: theme, accent: accent, compact: compact) {
                if showDrumMachine {
                    withAnimation(.spring(response: 0.3)) { showDrumMachine = false }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            modeSegment(icon: "music.quarternote.3", label: "DRUMS", active: showDrumMachine,
                        theme: theme, accent: accent, compact: compact) {
                if !showDrumMachine {
                    withAnimation(.spring(response: 0.3)) { showDrumMachine = true }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        }
        .padding(3)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    private func modeSegment(icon: String, label: String, active: Bool,
                             theme: AppTheme, accent: Color, compact: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                if !compact {
                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                        .kerning(0.5)
                }
            }
            .foregroundColor(active ? .white : theme.secondaryText)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(width: compact ? 34 : nil, height: 30)
            .background(active ? accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 2))
        }
    }

    private func voiceDots(theme: AppTheme, accent: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .fill(i < engine.voices.count ? accent : theme.primaryText.opacity(0.12))
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.1), value: engine.voices.count)
            }
        }
    }

    private func midiChip(theme: AppTheme, accent: Color) -> some View {
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
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
            .strokeBorder(theme.panelBorder, lineWidth: 1))
    }

    private func groupDivider(theme: AppTheme) -> some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(theme.panelBorder)
            .frame(width: 1, height: 26)
            .opacity(0.7)
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

// MARK: - Header CPU / RAM meter

/// Always-visible performance readout in the header. Observes the shared
/// Diagnostics sampler (running for the app's lifetime). Compact mode shows CPU
/// only; expanded adds memory. Turns red when CPU is pegged so a performance
/// problem is obvious at a glance while playing.
struct HeaderMeter: View {
    @ObservedObject private var diag = Diagnostics.shared
    let compact: Bool
    let theme: AppTheme

    var body: some View {
        let cpuWarn = diag.cpuPercent >= 85
        return HStack(spacing: 7) {
            metric(icon: "cpu", value: String(format: "%.0f%%", diag.cpuPercent),
                   valueWidth: 30, warn: cpuWarn)
            if !compact {
                metric(icon: "memorychip",
                       value: String(format: "%.0f MB", diag.memoryMB),
                       valueWidth: 50, warn: diag.memoryMB > 300)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius / 1.5)
            .strokeBorder(cpuWarn ? Color.red.opacity(0.65) : theme.panelBorder, lineWidth: 1))
    }

    // Fixed-width, trailing-aligned monospaced value so the readout (and the whole
    // header) doesn't shift when the number gains or loses a digit (e.g. 9% → 100%).
    private func metric(icon: String, value: String, valueWidth: CGFloat, warn: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: valueWidth, alignment: .trailing)
        }
        .foregroundColor(warn ? .red : theme.secondaryText)
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
