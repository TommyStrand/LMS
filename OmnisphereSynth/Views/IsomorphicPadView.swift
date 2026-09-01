import SwiftUI

/// Isomorphic fretboard-style play surface.
///
/// Layout: 4 rows × 13 columns. Each row is offset from the one below it by
/// a perfect-4th (5 semitones), matching standard bass/guitar EADG tuning. Any
/// chord or scale shape looks identical regardless of the root, making it easy
/// to transpose by sliding your hand left/right.
///
/// Scale notes are lit; chromatic passing tones are dim. Root notes glow with
/// the preset accent colour. Multi-touch is fully supported.
struct IsomorphicPadView: View {
    var engine: AudioEngine
    @Environment(ThemeManager.self) var themeManager
    let preset: SynthPreset

    private let nRows       = 4
    private let nCols       = 13
    private let rowInterval = 5   // perfect 4th

    // touchID → MIDI note currently sounding
    @State private var activeCells: [Int: Int] = [:]

    // ── Layout helpers ────────────────────────────────────────────────────

    private var baseNote: Int {
        // Lowest row starts at root in the chosen octave, clamped so no row
        // exceeds MIDI 127.
        let root = themeManager.rootNote + themeManager.transposeOctave * 12
        return max(24, min(75, root))   // 75 + 3*5 + 12 = 102 ≤ 127
    }

    private func midi(row: Int, col: Int) -> Int {
        // row 0 = top, row (nRows-1) = bottom (lowest pitch)
        baseNote + (nRows - 1 - row) * rowInterval + col
    }

    private func isInScale(_ note: Int) -> Bool {
        let rootPc = ((themeManager.rootNote % 12) + 12) % 12
        let notePc = ((note % 12) + 12) % 12
        let interval = (notePc - rootPc + 12) % 12
        return themeManager.scale.intervals.contains(interval)
    }

    private func isRoot(_ note: Int) -> Bool {
        ((note % 12) + 12) % 12 == ((themeManager.rootNote % 12) + 12) % 12
    }

    private func noteName(_ note: Int) -> String {
        ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"][((note % 12) + 12) % 12]
    }

    // ── Body ─────────────────────────────────────────────────────────────

    var body: some View {
        let theme  = themeManager.current
        let accent = theme.accent(for: Color(hex: preset.color))

        GeometryReader { geo in
            let cellW = geo.size.width  / CGFloat(nCols)
            let cellH = geo.size.height / CGFloat(nRows)

            ZStack(alignment: .topLeading) {

                // ── Cell grid ─────────────────────────────────────────────
                VStack(spacing: 0) {
                    ForEach(0..<nRows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<nCols, id: \.self) { col in
                                cellView(row: row, col: col,
                                         cellW: cellW, cellH: cellH,
                                         accent: accent, theme: theme)
                            }
                        }
                    }
                }

                // ── Touch handler ─────────────────────────────────────────
                SimultaneousTouchGesture { events in
                    for ev in events {
                        let col = max(0, min(nCols - 1, Int(ev.location.x / cellW)))
                        let row = max(0, min(nRows - 1, Int(ev.location.y / cellH)))
                        let note = midi(row: row, col: col)
                        switch ev.phase {
                        case .began:
                            activeCells[ev.id] = note
                            engine.noteOn(touchID: ev.id, note: note,
                                          velocity: 0.82, x: 0.5, y: 0.5)
                        case .moved:
                            if note != activeCells[ev.id] {
                                engine.noteOff(touchID: ev.id)
                                activeCells[ev.id] = note
                                engine.noteOn(touchID: ev.id, note: note,
                                              velocity: 0.82, x: 0.5, y: 0.5)
                            }
                        default:
                            activeCells.removeValue(forKey: ev.id)
                            engine.noteOff(touchID: ev.id)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(hex: preset.color).opacity(0.45), lineWidth: 1.5))
    }

    // ── Single cell ───────────────────────────────────────────────────────

    @ViewBuilder
    private func cellView(row: Int, col: Int, cellW: CGFloat, cellH: CGFloat,
                          accent: Color, theme: AppTheme) -> some View {
        let note     = midi(row: row, col: col)
        let inScale  = isInScale(note)
        let rootNote = isRoot(note)
        let active   = activeCells.values.contains(note)

        ZStack {
            // Background
            Rectangle().fill(
                active   ? accent :
                rootNote ? accent.opacity(0.32) :
                inScale  ? theme.panelBackground.opacity(0.75) :
                           theme.appBackground.opacity(0.35)
            )
            .animation(.easeOut(duration: 0.08), value: active)

            // Row separator + column separator lines
            Rectangle()
                .strokeBorder(theme.panelBorder.opacity(inScale ? 0.35 : 0.2), lineWidth: 0.5)

            // Note label (only when cell is tall enough)
            if cellH > 28 {
                VStack(spacing: 1) {
                    Text(noteName(note))
                        .font(.system(size: min(11, cellH * 0.28),
                                      weight: rootNote ? .bold : .regular,
                                      design: theme.fontDesign))
                        .foregroundColor(
                            active   ? .white :
                            rootNote ? accent :
                            inScale  ? theme.primaryText.opacity(0.75) :
                                       theme.secondaryText.opacity(0.35)
                        )
                    // Octave dot row for root notes so they stand out across octaves
                    if rootNote && cellH > 38 {
                        Circle()
                            .fill(active ? Color.white.opacity(0.8) : accent.opacity(0.55))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .frame(width: cellW, height: cellH)
    }
}
