import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer

struct ContentView: View {
    // App-lifetime @Observable models, created once in SuperNovaPadApp and injected
    // via the environment. (Creating them here with `@State var x = X()` would
    // re-allocate an AudioEngine / CoreMIDI client on every ContentView re-init and
    // throw it away — see the note in SuperNovaPadApp.) SwiftUI tracks exactly
    // which of their properties this body reads, so e.g. the 30 Hz waveform
    // publish no longer invalidates this whole view.
    @Environment(AudioEngine.self)    private var engine
    @Environment(ThemeManager.self)   private var themeManager
    @Environment(MIDIController.self) private var midi
    @Environment(DrumEngine.self)     private var drum
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AudioRecorder.self)  private var recorder
    @Environment(LooperEngine.self)   private var looper
    @State private var selectedPresetIndex = 0
    // iPad: the sound controls are a drawer opened from the footer's SOUND button,
    // closed at launch so the play surface gets the room. iPhone keeps them open.
    @State private var showControls    = UIDevice.current.userInterfaceIdiom != .pad
    @State private var showSettings    = false
    @State private var midiActivityLit = false
    @State private var showDrumMachine = false
    @State private var showShareSheet  = false
    @State private var recBlink        = false
    @State private var showBlob        = false   // blob background visualizer
    /// CPU / RAM readout in the iPad header (More menu). Off by default; the meter
    /// still appears by itself while the CPU is pegged.
    @AppStorage("showHeaderMeter") private var showMeter = false

    // Initialise NowPlayingManager once so remote commands are registered early
    private let nowPlaying = NowPlayingManager.shared

    var currentPreset: SynthPreset { SynthPreset.presets[selectedPresetIndex] }

    var body: some View {
        let theme = themeManager.current
        GeometryReader { geo in
            ZStack {
                themeManager.screenBackground.ignoresSafeArea()

                // Instrument scene (Settings → Instrument backdrop). Decorative only.
                // iPhone: behind the whole screen. iPad places it behind the play
                // area instead (see ipadLayout), clear of the header and preset strip.
                if geo.size.width <= 680 {
                    backdropLayer(featherTop: false)
                }

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
        .preferredColorScheme(themeManager.current.colorScheme)
        .onAppear {
            midi.attach(to: engine)
            Diagnostics.shared.startSampling()   // drives the always-on header meter
            looper.audioEngine = engine
            engine.looper      = looper
            engine.yAxisMorph  = themeManager.yAxisMorph
            themeManager.activePresetName  = currentPreset.name
            themeManager.activePresetColor = currentPreset.color
        }
        .onChange(of: themeManager.yAxisMorph) { _, morph in
            engine.yAxisMorph = morph
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { recorder.exportURL = nil }) {
            if let url = recorder.exportURL {
                ShareSheet(url: url)
            }
        }
        .onChange(of: midi.activityPulse) {
            midiActivityLit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                midiActivityLit = false
            }
        }
        .onChange(of: recorder.exportURL) { _, url in
            if url != nil { showShareSheet = true }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    recBlink = true
                }
            } else {
                withAnimation(.default) { recBlink = false }
            }
        }
        // MARK: - AirPlay 2 / Now Playing updates
        .onChange(of: selectedPresetIndex) { _, idx in
            withAnimation(.easeInOut(duration: 0.4)) {
                themeManager.activePresetName  = SynthPreset.presets[idx].name
                themeManager.activePresetColor = SynthPreset.presets[idx].color
            }
            nowPlaying.update(presetName: SynthPreset.presets[idx].name,
                              isLiveInstrument: true, isPlaying: false)
        }
        .onChange(of: showDrumMachine) { _, drumActive in
            let title = drumActive
                ? DrumPattern.all[drum.patternIndex].name + " — Drum"
                : SynthPreset.presets[selectedPresetIndex].name
            nowPlaying.update(presetName: title, isLiveInstrument: true,
                              isPlaying: drumActive && drum.isPlaying)
        }
        .onChange(of: drum.patternIndex) { _, idx in
            guard showDrumMachine else { return }
            nowPlaying.update(presetName: DrumPattern.all[idx].name + " — Drum",
                              isLiveInstrument: true, isPlaying: drum.isPlaying)
        }
        .onChange(of: drum.isPlaying) { _, playing in
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

    // MARK: - Backdrop

    @ViewBuilder
    private func backdropLayer(featherTop: Bool) -> some View {
        if let source = themeManager.backdrop {
            Group {
                switch source {
                case .image(let url):
                    BackdropView(url: url, dim: themeManager.backdropDim, featherTop: featherTop) { palette in
                        withAnimation(.easeInOut(duration: 0.45)) {
                            themeManager.setPalette(palette, for: url)
                        }
                    }
                case .abstract(let seed, let color):
                    AbstractBackdropView(seed: seed, color: color,
                                         dim: themeManager.backdropDim, featherTop: featherTop)
                }
            }
            .transition(.opacity)
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

    // MARK: - iPad layout
    //
    // Top to bottom: header, preset strip (scene thumbnails), the play surface
    // across the full width, the sound drawer (when open) and a footer with the
    // looper and the SOUND button. The instrument scene sits behind everything
    // below the preset strip, so the instrument shows through the play surface
    // rather than hiding under the header.

    private func ipadLayout(theme: AppTheme, geo: GeometryProxy) -> some View {
        let accent = theme.accent(for: Color(hex: currentPreset.color))
        return VStack(spacing: 0) {
            header(theme: theme, compact: false)

            PresetSelectorView(selectedIndex: $selectedPresetIndex, engine: engine) { preset in
                engine.applyPreset(preset)
            }
            .padding(.top, 4)

            VStack(spacing: 0) {
                playSurface(preset: currentPreset)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showControls {
                    ControlsView(engine: engine, wide: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 0) {
                    LooperView(looper: looper, theme: theme, accent: accent)
                    soundButton(theme: theme, accent: accent)
                        .padding(.trailing, 16)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .background {
                // Starts a little above the play surface and feathers in, so
                // there is no hard edge under the preset strip.
                backdropLayer(featherTop: true)
                    .padding(.top, -28)
            }
        }
    }

    /// Footer button that opens / closes the sound-controls drawer (iPad).
    private func soundButton(theme: AppTheme, accent: Color) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { showControls.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Text("SOUND")
                    .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                    .kerning(1)
                Image(systemName: showControls ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(showControls ? .white : theme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(showControls ? accent : theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(showControls ? accent : theme.panelBorder, lineWidth: 1))
        }
        .accessibilityLabel(showControls ? "Hide sound controls" : "Show sound controls")
    }

    // MARK: - Header
    //
    // iPad: what is playing on the left, the two mode switches (PLAY / DRUMS and
    // the play mode) in the middle, and on the right only what is needed while
    // playing — octave, MIDI activity, record, AirPlay — plus a More menu holding
    // the visualizer, the performance meter and Settings.
    // iPhone (`compact`): one tight row of icon buttons, no menu.

    private func header(theme: AppTheme, compact: Bool) -> some View {
        let accent = theme.accent(for: Color(hex: currentPreset.color))
        return HStack(spacing: compact ? 8 : 10) {
            brandView(theme: theme, accent: accent, compact: compact)
            Spacer(minLength: 8)
            if compact {
                transposeControls(theme: theme, accent: accent)
                modeToggle(theme: theme, accent: accent, compact: true)
                if !showDrumMachine {
                    playModeControl(theme: theme, accent: accent, compact: true)
                }
                if midi.isConnected { midiChip(theme: theme, accent: accent) }
                HeaderMeter(compact: true, theme: theme)
                compactSystemButtons(theme: theme, accent: accent)
            } else {
                modeToggle(theme: theme, accent: accent, compact: false)
                if !showDrumMachine {
                    playModeControl(theme: theme, accent: accent, compact: false)
                }
                Spacer(minLength: 8)
                transposeControls(theme: theme, accent: accent)
                if midi.isConnected { midiChip(theme: theme, accent: accent) }
                HeaderMeter(compact: false, theme: theme, onlyWhenWarning: !showMeter)
                recordButton(theme: theme, accent: accent)
                airPlayButton(theme: theme)
                moreMenu(theme: theme)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: Header clusters

    private func compactSystemButtons(theme: AppTheme, accent: Color) -> some View {
        HStack(spacing: 8) {
            iconButton(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle",
                       active: showControls, theme: theme) {
                withAnimation(.spring(response: 0.3)) { showControls.toggle() }
            }
            iconButton(systemName: "waveform.circle", active: showBlob, theme: theme) {
                withAnimation(.spring(response: 0.4)) { showBlob.toggle() }
            }
            recordButton(theme: theme, accent: accent)
            airPlayButton(theme: theme)
            iconButton(systemName: "gearshape", active: false, theme: theme) {
                showSettings = true
            }
        }
    }

    private func airPlayButton(theme: AppTheme) -> some View {
        AirPlayButton(tintColor: UIColor(theme.secondaryText))
            .frame(width: 36, height: 36)
            .panelSurface(theme, radius: theme.chipRadius)
    }

    /// iPad: the less-used actions, behind one button.
    private func moreMenu(theme: AppTheme) -> some View {
        Menu {
            Toggle(isOn: $showBlob) {
                Label("Visualizer", systemImage: "waveform.circle")
            }
            Toggle(isOn: $showMeter) {
                Label("Performance meter", systemImage: "cpu")
            }
            Divider()
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .frame(width: 36, height: 36)
                .panelSurface(theme, radius: theme.chipRadius)
        }
        .accessibilityLabel("More")
    }

    // MARK: Header pieces

    /// iPhone: just the wordmark. iPad: wordmark, what is being played (preset, or
    /// the drum pattern) and its context (key and play mode).
    private func brandView(theme: AppTheme, accent: Color, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("SUPERNOVA PAD")
                .font(.system(size: compact ? 11 : 10, weight: .bold, design: theme.fontDesign))
                .foregroundColor(accent.opacity(0.9))
                .kerning(compact ? 1.5 : 3)
            if !compact {
                Text(showDrumMachine ? DrumPattern.all[drum.patternIndex].name : currentPreset.name)
                    .font(.system(size: 21, weight: .semibold, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText)
                    .minimumScaleFactor(0.7)
                Text(showDrumMachine ? "Drum machine" : brandSubtitle)
                    .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .lineLimit(1)
    }

    /// e.g. "C Major · Grid"
    private var brandSubtitle: String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let root  = names[((themeManager.rootNote % 12) + 12) % 12]
        return "\(root) \(themeManager.scale.label) · \(themeManager.playMode.label)"
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
        .panelSurface(theme, radius: theme.chipRadius)
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
                            .clipShape(RoundedRectangle(cornerRadius: max(2, theme.chipRadius - 3)))
                    }
                }
            }
            .padding(3)
            .panelSurface(theme, radius: theme.chipRadius)
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
        .panelSurface(theme, radius: theme.chipRadius)
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
            .clipShape(RoundedRectangle(cornerRadius: max(2, theme.chipRadius - 3)))
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
        .panelSurface(theme, radius: theme.chipRadius)
    }

    private func iconButton(systemName: String, active: Bool, theme: AppTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundColor(active
                    ? theme.accent(for: Color(hex: currentPreset.color))
                    : theme.secondaryText)
                .frame(width: 36, height: 36)
                .panelSurface(theme, radius: theme.chipRadius)
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
            .panelSurface(theme, radius: theme.chipRadius,
                          border: recorder.isRecording ? recColor.opacity(recBlink ? 0.9 : 0.3) : nil)
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
    // @Observable singleton: reads in `body` are tracked automatically, no wrapper needed.
    private let diag = Diagnostics.shared
    let compact: Bool
    let theme: AppTheme
    /// iPad default: stay out of the header unless the CPU is pegged.
    var onlyWhenWarning: Bool = false

    var body: some View {
        let cpuWarn = diag.cpuPercent >= 85
        if !onlyWhenWarning || cpuWarn {
            readout(cpuWarn: cpuWarn)
        }
    }

    private func readout(cpuWarn: Bool) -> some View {
        HStack(spacing: 7) {
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
        .panelSurface(theme, radius: theme.chipRadius, border: cpuWarn ? Color.red.opacity(0.65) : nil)
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

// MARK: - Instrument backdrop

/// Shared framing for every backdrop: the scene sits against the trailing edge,
/// feathers out on its leading side, and is dimmed for legibility.
struct BackdropFrame<Content: View>: View {
    let dim: Double
    /// Share of the screen width the scene occupies, anchored to the trailing
    /// edge. On iPad (0.66) it sits behind the play surface and feathers out
    /// before the preset list and controls on the left; 1 = full screen.
    let trailingFraction: CGFloat
    /// Fade the top edge in (iPad: the scene starts just under the preset strip).
    var featherTop: Bool = false
    @ViewBuilder let scene: () -> Content

    var body: some View {
        GeometryReader { geo in
            Color.black
                // Top-aligned: when the frame is wider than the art, crop the
                // (dark, empty) floor rather than the instrument.
                .overlay(alignment: .top) { scene() }
                .overlay {
                    // Dim, a little lighter at the top where the instrument sits and
                    // darker towards the floor so grid labels stay readable.
                    LinearGradient(colors: [.black.opacity(dim * 0.9), .black.opacity(min(0.97, dim + 0.1))],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(width: geo.size.width * trailingFraction, height: geo.size.height)
                .clipped()
                .mask {
                    // Soft left edge so the scene melts into the plain background.
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: trailingFraction < 1 ? 0.22 : 0)
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: featherTop ? 0.12 : 0)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A painted scene from Resources/Backgrounds. The image is decoded off the main
/// thread (preparingForDisplay) so switching presets never stalls touch handling,
/// and cross-fades when the preset changes.
struct BackdropView: View {
    let url: URL
    let dim: Double
    var trailingFraction: CGFloat = 1
    var featherTop: Bool = false
    /// Called on the main thread with the colours sampled from each loaded scene.
    var onPalette: (BackdropPalette) -> Void = { _ in }
    @State private var image: UIImage?

    var body: some View {
        BackdropFrame(dim: dim, trailingFraction: trailingFraction, featherTop: featherTop) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage, BackdropPalette)? in
                guard let raw = UIImage(contentsOfFile: url.path) else { return nil }
                let palette = BackdropPalette.extract(rgba: Self.thumbnailPixels(of: raw))
                return (raw.preparingForDisplay() ?? raw, palette)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { image = loaded?.0 }
            if let palette = loaded?.1 { onPalette(palette) }
        }
    }

    /// RGBA bytes of a 32×21 thumbnail — plenty for picking a palette.
    nonisolated static func thumbnailPixels(of image: UIImage, width: Int = 32, height: Int = 21) -> [UInt8] {
        guard let cg = image.cgImage else { return [] }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? px : []
    }
}

/// Generated scene for presets without an image (the synth pads): soft glows in
/// hues around the preset colour and a few stars, laid out by `AbstractScene`.
struct AbstractBackdropView: View {
    let seed: String
    let color: BackdropPalette.RGB
    let dim: Double
    var trailingFraction: CGFloat = 1
    var featherTop: Bool = false

    var body: some View {
        let layout = AbstractScene.layout(seed: seed)
        let light  = color.scaled(toMax: 0.9)   // dark preset colours still glow
        BackdropFrame(dim: dim, trailingFraction: trailingFraction, featherTop: featherTop) {
            Canvas { ctx, size in
                for glow in layout.glows {
                    let c      = light.rotated(byTurns: glow.hueTurns).color
                    let centre = CGPoint(x: glow.x * size.width, y: glow.y * size.height)
                    let radius = glow.radius * size.width
                    let rect   = CGRect(x: centre.x - radius, y: centre.y - radius,
                                        width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .radialGradient(Gradient(colors: [c.opacity(glow.opacity), c.opacity(0)]),
                                                   center: centre, startRadius: 0, endRadius: radius))
                }
                for star in layout.stars {
                    let rect = CGRect(x: star.x * size.width, y: star.y * size.height,
                                      width: star.size, height: star.size)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(star.opacity)))
                }
            }
            .id(seed)
            .transition(.opacity)
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

#Preview {
    ContentView()
        .environment(AudioEngine())
        .environment(ThemeManager())
        .environment(MIDIController())
        .environment(DrumEngine())
        .environment(FavoritesStore())
        .environment(AudioRecorder())
        .environment(LooperEngine())
}
