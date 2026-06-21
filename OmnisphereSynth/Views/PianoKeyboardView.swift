import SwiftUI
import Combine

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
    /// Wall-clock time of each finger's last *significant* move — drives the
    /// "snap to the nearest scale note once the finger stops" behaviour.
    @State private var lastMoveTime:    [Int: Double]  = [:]
    /// Fingers that have already settled onto a scale note (so we snap once, not
    /// every timer tick, and resume gliding the moment they move again).
    @State private var snappedTouches:  Set<Int>       = []
    /// Fingers that have actually slid (not just tapped). Only these snap to scale
    /// on rest — a plain tap on a black key must keep its exact chromatic pitch.
    @State private var slidTouches:     Set<Int>       = []

    // pressedKeys is derived on-the-fly from touchToKey for SwiftUI key redraws.
    private var pressedKeys: Set<Int> { Set(touchToKey.values) }

    // Drives the settle check. A finger that stops moving for `settleDelay`
    // seconds eases (via SynthVoice's smooth pitch glide) to the nearest scale
    // note — MorphWiz's "slide freely, land in tune" gesture.
    private let settleTimer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()
    private let settleDelay: Double = 0.08
    private let pitchPerKey  = 12.0 / 7.0   // semitones per white-key width

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
            .onReceive(settleTimer) { _ in
                settleStoppedFingers(dims: dims, geo: geo)
            }
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
                lastMoveTime[ev.id]    = Date().timeIntervalSinceReferenceDate
                snappedTouches.remove(ev.id)
                slidTouches.remove(ev.id)
                engine.noteOn(touchID: ev.id, note: note,
                              velocity: 0.65 + y * 0.35, x: x, y: y)

            case .moved:
                guard let originX = touchOriginX[ev.id] else { break }

                // Did the finger actually travel, or is this sub-pixel jitter while
                // it's effectively held still? We must not reset the settle clock on
                // jitter, or a stationary finger would never snap.
                let prev = touchLocations[ev.id]
                let movedEnough = prev.map {
                    abs(loc.x - $0.x) > 1.5 || abs(loc.y - $0.y) > 1.5
                } ?? true
                touchLocations[ev.id] = loc

                if movedEnough {
                    // Sliding: glide pitch continuously and reset the settle clock so
                    // we only snap once the finger comes to rest.
                    lastMoveTime[ev.id] = Date().timeIntervalSinceReferenceDate
                    snappedTouches.remove(ev.id)

                    // 12/7 ≈ 1.714 semitones per white-key-width: 12 chromatic
                    // semitones spread across 7 white keys per octave.
                    let semitones = Float(loc.x - originX) / Float(dims.keyW) * Float(pitchPerKey)
                    let currentKey = noteAt(loc, dims: dims)
                    if currentKey != touchToKey[ev.id] { touchToKey[ev.id] = currentKey }
                    // Mark as a real slide once the finger leaves its starting key by
                    // ~half a key — only slides snap to scale on rest (taps don't).
                    if abs(loc.x - originX) > dims.keyW * 0.4 { slidTouches.insert(ev.id) }
                    engine.updateGlissando(touchID: ev.id, semitones: semitones, x: x, y: y)
                } else {
                    // Held still (incl. already snapped): keep expression (Y) live but
                    // leave the pitch alone so the snapped note isn't dragged off-tune.
                    engine.updateTouch(touchID: ev.id, x: x, y: y)
                }

            default:
                touchToKey.removeValue(forKey: ev.id)
                touchOriginNote.removeValue(forKey: ev.id)
                touchOriginX.removeValue(forKey: ev.id)
                touchLocations.removeValue(forKey: ev.id)
                lastMoveTime.removeValue(forKey: ev.id)
                snappedTouches.remove(ev.id)
                slidTouches.remove(ev.id)
                engine.noteOff(touchID: ev.id)
            }
        }
    }

    // MARK: - Snap-after-slide

    /// Once a finger has been still for `settleDelay`, ease its pitch to the nearest
    /// in-scale note. We just change the glissando *target*; SynthVoice's smooth
    /// pitch glide (~75 ms time constant) does the easing, so the landing is a slur,
    /// not a click. Snaps once per rest (tracked by `snappedTouches`).
    private func settleStoppedFingers(dims: KeyDims, geo: GeometryProxy) {
        guard !touchLocations.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        for (id, loc) in touchLocations {
            guard slidTouches.contains(id),          // only snap fingers that slid
                  !snappedTouches.contains(id),
                  let originX    = touchOriginX[id],
                  let originNote = touchOriginNote[id],
                  let lastMove   = lastMoveTime[id],
                  now - lastMove >= settleDelay
            else { continue }

            let semitones   = Double(loc.x - originX) / Double(dims.keyW) * pitchPerKey
            let pitch       = Double(originNote) + semitones
            let snappedMidi = nearestScaleMidi(to: pitch)
            let target      = Float(Double(snappedMidi) - Double(originNote))
            let y           = Float(1 - loc.y / geo.size.height)

            engine.updateGlissando(touchID: id, semitones: target,
                                   x: Float(loc.x / geo.size.width), y: y)
            touchToKey[id] = snappedMidi
            snappedTouches.insert(id)
        }
    }

    /// Nearest MIDI note belonging to the current scale (root + scale degrees) to a
    /// fractional pitch. Falls back to the rounded pitch for the chromatic scale.
    private func nearestScaleMidi(to pitch: Double) -> Int {
        let rootPc    = ((themeManager.rootNote % 12) + 12) % 12
        let intervals = Set(themeManager.scale.intervals)
        let center    = Int(pitch.rounded())
        var best      = center
        var bestDist  = Double.infinity
        for cand in (center - 6)...(center + 6) {
            let pc = (((cand - rootPc) % 12) + 12) % 12
            guard intervals.contains(pc) else { continue }
            let d = abs(Double(cand) - pitch)
            if d < bestDist { bestDist = d; best = cand }
        }
        return min(127, max(0, best))
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
