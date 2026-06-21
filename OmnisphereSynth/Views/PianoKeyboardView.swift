import SwiftUI

/// Piano keyboard with MorphWiz-style continuous pitch control.
///
/// Unlike a standard piano keyboard where sliding between keys retriggers each
/// note, this view uses `updateGlissando` to smoothly bend the pitch as the
/// finger moves. The voice never retriggers — it just follows the finger:
///
///   • X-axis: continuous pitch from wherever the finger first landed.
///     One white-key-width ≈ 12/7 semitones (the average piano ratio).
///     Sliding right bends up; sliding left bends down.
///
///   • Y-axis: expression. Low on the key = quiet + no vibrato; high on the
///     key = full brightness + vibrato. This feeds `lfoDepthMod` and
///     `filterCutoffMod` in the voice (already in the engine, unchanged).
///
///   • Glowing touch-point dot: follows the finger so you can see the current
///     pitch offset (horizontal) and expression depth (vertical / brightness).
///
/// Multi-touch: each finger is independent; voices persist until lift.
struct PianoKeyboardView: View {
    @ObservedObject var engine: AudioEngine
    @EnvironmentObject var themeManager: ThemeManager
    let preset: SynthPreset

    // MARK: - Touch state

    /// Key (MIDI note) physically under each finger right now — for visual highlighting.
    @State private var touchToKey:      [Int: Int]     = [:]
    /// MIDI note where each finger originally landed — anchor for the pitch-bend calc.
    @State private var touchOriginNote: [Int: Int]     = [:]
    /// X coordinate where each finger originally landed — anchor for pitch-bend.
    @State private var touchOriginX:    [Int: CGFloat] = [:]
    /// Current touch positions — used to draw the glowing indicators.
    @State private var touchLocations:  [Int: CGPoint] = [:]

    // pressedKeys is derived on-the-fly from touchToKey for SwiftUI key redraws.
    private var pressedKeys: Set<Int> { Set(touchToKey.values) }

    // MARK: - Note layout

    private var startNote: Int {
        max(0, min(themeManager.rootNote + themeManager.transposeOctave * 12, 96))
    }

    private let whiteOffsets     = [0, 2, 4, 5, 7, 9, 11]
    private let blackAfterWhite: [Int?] = [1, 3, nil, 6, 8, 10, nil]

    private var whiteNotes: [Int] {
        var r: [Int] = []
        for oct in 0..<2 {
            for off in whiteOffsets {
                let n = startNote + oct * 12 + off
                if n <= 127 { r.append(n) }
            }
        }
        return r
    }

    private var blackNotes: [(note: Int, afterWhiteIndex: Int)] {
        var r: [(Int, Int)] = []
        for oct in 0..<2 {
            for (wi, bOpt) in blackAfterWhite.enumerated() {
                guard let b = bOpt else { continue }
                let note = startNote + oct * 12 + b
                if note <= 127 { r.append((note, oct * whiteOffsets.count + wi)) }
            }
        }
        return r
    }

    // MARK: - Body

    var body: some View {
        let theme  = themeManager.current
        let accent = theme.accent(for: Color(hex: preset.color))

        GeometryReader { geo in
            let dims = keyDims(geo: geo)

            ZStack(alignment: .topLeading) {

                // ── White keys ─────────────────────────────────────────────
                HStack(spacing: 0) {
                    ForEach(whiteNotes, id: \.self) { note in
                        whiteKey(note: note, dims: dims, theme: theme, accent: accent)
                    }
                }

                // ── Black keys ─────────────────────────────────────────────
                ForEach(blackNotes, id: \.note) { item in
                    // Centre x of this black key
                    let cx = dims.keyW * CGFloat(item.afterWhiteIndex) + dims.keyW
                    blackKey(note: item.note, dims: dims, theme: theme, accent: accent)
                        .position(x: cx, y: dims.blackH * 0.5)
                }

                // ── Note labels on pressed white keys ──────────────────────
                HStack(spacing: 0) {
                    ForEach(Array(whiteNotes.enumerated()), id: \.element) { _, note in
                        if pressedKeys.contains(note) {
                            VStack {
                                Spacer()
                                Text(midiToNoteName(note))
                                    .font(.system(size: max(9, dims.keyW * 0.3),
                                                  weight: .bold,
                                                  design: theme.fontDesign))
                                    .foregroundColor(accent)
                                    .padding(.bottom, 8)
                            }
                            .frame(width: dims.keyW, height: dims.keyH)
                        } else {
                            Spacer().frame(width: dims.keyW, height: dims.keyH)
                        }
                    }
                }
                .allowsHitTesting(false)

                // ── Glowing touch-point indicators ─────────────────────────
                // The dot follows the finger exactly, giving immediate visual
                // feedback on pitch position (X) and expression depth (Y).
                ForEach(touchLocations.keys.sorted(), id: \.self) { id in
                    if let loc = touchLocations[id] {
                        let yExpr = CGFloat(1 - loc.y / geo.size.height).clamped(to: 0...1)
                        touchDot(at: loc, yExpr: yExpr, accent: accent)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 1.2))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius * 1.2)
                    .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
            )
            .shadow(color: accent.opacity(0.15), radius: 10)
            .overlay(
                SimultaneousTouchGesture { events in
                    handleTouches(events, dims: dims, geo: geo, accent: accent)
                }
            )
        }
    }

    // MARK: - Touch handling

    private func handleTouches(_ events: [TouchEvent],
                               dims: KeyDims, geo: GeometryProxy,
                               accent: Color) {
        for ev in events {
            let loc = ev.location
            let x   = Float(loc.x / geo.size.width)
            let y   = Float(1 - loc.y / geo.size.height)

            switch ev.phase {

            case .began:
                let note = noteAt(loc, dims: dims)
                touchToKey[ev.id]      = note
                touchOriginNote[ev.id] = note
                touchOriginX[ev.id]    = loc.x
                touchLocations[ev.id]  = loc
                engine.noteOn(touchID: ev.id, note: note,
                              velocity: 0.65 + y * 0.35, x: x, y: y)

            case .moved:
                guard let originX    = touchOriginX[ev.id],
                      let originNote = touchOriginNote[ev.id] else { break }

                // Continuous pitch: X displacement from origin → semitones.
                // 12/7 ≈ 1.714 semitones per white-key-width (average piano layout):
                // 12 chromatic semitones spread across 7 white keys per octave.
                let semitones = Float(loc.x - originX) / Float(dims.keyW) * (12.0 / 7.0)

                touchLocations[ev.id] = loc

                // Track which physical key is under the finger (for highlighting).
                let currentKey = noteAt(loc, dims: dims)
                if currentKey != touchToKey[ev.id] {
                    touchToKey[ev.id] = currentKey
                }

                // Pass both pitch bend AND expression (Y) through glissando.
                // `pitchBendSemitones` is audio-thread smooth (see SynthVoice).
                // Y drives filterCutoffMod + lfoDepthMod (vibrato).
                _ = originNote   // suppress "unused" warning; anchors the semitone calc
                engine.updateGlissando(touchID: ev.id, semitones: semitones, x: x, y: y)

            default:
                touchToKey.removeValue(forKey: ev.id)
                touchOriginNote.removeValue(forKey: ev.id)
                touchOriginX.removeValue(forKey: ev.id)
                touchLocations.removeValue(forKey: ev.id)
                engine.noteOff(touchID: ev.id)
            }
        }
    }

    // MARK: - Key views

    private func whiteKey(note: Int, dims: KeyDims,
                          theme: AppTheme, accent: Color) -> some View {
        let pressed = pressedKeys.contains(note)
        // Y position of touch on this key (for gradient depth feedback)
        let touchY = touchLocations.first { touchToKey[$0.key] == note }?.value.y
        let depth  = touchY.map { (1 - $0 / dims.keyH).clamped(to: 0...1) } ?? 0

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    pressed
                    ? LinearGradient(
                        colors: [
                            accent.opacity(0.12 + depth * 0.28),
                            accent.opacity(0.38 + depth * 0.32)
                        ],
                        startPoint: .top, endPoint: .bottom
                      )
                    : LinearGradient(
                        colors: [
                            theme.id == "ivory" ? Color(hex: "#FAF6F0") : Color.white.opacity(0.96),
                            theme.id == "ivory" ? Color(hex: "#EDE8E0") : Color.white.opacity(0.89)
                        ],
                        startPoint: .top, endPoint: .bottom
                      )
                )
                .padding(.horizontal, 1.5)
                .padding(.vertical, 1)
        }
        .frame(width: dims.keyW, height: dims.keyH)
        .overlay(
            Rectangle()
                .fill(theme.panelBorder.opacity(0.3))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
        .animation(.easeOut(duration: 0.07), value: pressed)
    }

    private func blackKey(note: Int, dims: KeyDims,
                          theme: AppTheme, accent: Color) -> some View {
        let pressed = pressedKeys.contains(note)
        return RoundedRectangle(cornerRadius: 4)
            .fill(pressed
                  ? accent.opacity(0.78)
                  : Color(hex: theme.id == "ivory" ? "#1A1208" : "#0A0A0A"))
            .frame(width: dims.blackW, height: dims.blackH)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: pressed ? accent.opacity(0.55) : .clear, radius: 5)
            .animation(.easeOut(duration: 0.06), value: pressed)
    }

    // MARK: - Touch-point dot

    private func touchDot(at loc: CGPoint, yExpr: CGFloat, accent: Color) -> some View {
        ZStack {
            // Outer glow halo
            Circle()
                .fill(accent.opacity(0.14 + yExpr * 0.22))
                .frame(width: 52, height: 52)
                .blur(radius: 8)
            // Ring
            Circle()
                .strokeBorder(accent.opacity(0.5 + yExpr * 0.45), lineWidth: 1.8)
                .frame(width: 30, height: 30)
            // Centre dot — brighter when expression is higher (finger up the key)
            Circle()
                .fill(accent.opacity(0.65 + yExpr * 0.3))
                .frame(width: 7, height: 7)
        }
        .position(x: loc.x, y: loc.y)
        .allowsHitTesting(false)
    }

    // MARK: - Layout helpers

    struct KeyDims {
        let keyW: CGFloat    // white key width
        let keyH: CGFloat    // full height
        let blackW: CGFloat
        let blackH: CGFloat
    }

    private func keyDims(geo: GeometryProxy) -> KeyDims {
        let total  = max(1, whiteNotes.count)
        let keyW   = geo.size.width / CGFloat(total)
        return KeyDims(keyW: keyW, keyH: geo.size.height,
                       blackW: keyW * 0.58, blackH: geo.size.height * 0.60)
    }

    // MARK: - Hit test

    private func noteAt(_ loc: CGPoint, dims: KeyDims) -> Int {
        // Black keys first — they sit on top visually
        for item in blackNotes {
            let cx   = dims.keyW * CGFloat(item.afterWhiteIndex) + dims.keyW
            let rect = CGRect(x: cx - dims.blackW * 0.5, y: 0,
                              width: dims.blackW, height: dims.blackH)
            if rect.contains(loc) { return min(item.note, 127) }
        }
        let wi = max(0, min(Int(loc.x / dims.keyW), whiteNotes.count - 1))
        return min(whiteNotes[wi], 127)
    }

    private func midiToNoteName(_ midi: Int) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[((midi % 12) + 12) % 12])\((midi / 12) - 1)"
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
