import SwiftUI

struct PianoKeyboardView: View {
    @ObservedObject var engine: AudioEngine
    @EnvironmentObject var themeManager: ThemeManager
    let preset: SynthPreset

    @State private var pressedKeys: Set<Int> = []
    @State private var touchToNote: [Int: Int] = [:]

    // 2 octaves starting from root + transpose
    private var startNote: Int {
        let raw = themeManager.rootNote + themeManager.transposeOctave * 12
        return max(0, min(raw, 96))
    }

    private var octaveNotes: [Int] { Array(startNote...(startNote + 23)) }

    // White key MIDI offsets within an octave
    private let whiteOffsets = [0, 2, 4, 5, 7, 9, 11]
    // Black key MIDI offsets and their position between white keys (nil = no black key after that white key)
    private let blackAfterWhite: [Int?] = [1, 3, nil, 6, 8, 10, nil]

    private var whiteNotes: [Int] {
        var result: [Int] = []
        for oct in 0..<2 {
            for offset in whiteOffsets {
                let n = startNote + oct * 12 + offset
                if n <= 127 { result.append(n) }
            }
        }
        return result
    }

    private var blackNotes: [(note: Int, afterWhiteIndex: Int)] {
        var result: [(Int, Int)] = []
        for oct in 0..<2 {
            for (wi, bOpt) in blackAfterWhite.enumerated() {
                guard let bOffset = bOpt else { continue }
                let note = startNote + oct * 12 + bOffset
                let whiteIndex = oct * whiteOffsets.count + wi
                if note <= 127 { result.append((note, whiteIndex)) }
            }
        }
        return result
    }

    var body: some View {
        let theme = themeManager.current
        let accent = theme.accent(for: Color(hex: preset.color))

        GeometryReader { geo in
            let totalWhite = whiteNotes.count
            let keyW = geo.size.width / CGFloat(totalWhite)
            let keyH = geo.size.height
            let blackW = keyW * 0.58
            let blackH = keyH * 0.60

            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 0) {
                    ForEach(whiteNotes, id: \.self) { note in
                        whiteKey(note: note, width: keyW, height: keyH,
                                 theme: theme, accent: accent)
                    }
                }

                // Black keys
                ForEach(blackNotes, id: \.note) { item in
                    let x = keyW * CGFloat(item.afterWhiteIndex) + keyW - blackW * 0.5
                    blackKey(note: item.note, width: blackW, height: blackH,
                             theme: theme, accent: accent)
                        .position(x: x + blackW * 0.5, y: blackH * 0.5)
                }

                // Note name labels on pressed white keys
                HStack(spacing: 0) {
                    ForEach(Array(whiteNotes.enumerated()), id: \.element) { idx, note in
                        if pressedKeys.contains(note) {
                            VStack {
                                Spacer()
                                Text(midiToNoteName(note))
                                    .font(.system(size: max(9, keyW * 0.32), weight: .bold,
                                                  design: theme.fontDesign))
                                    .foregroundColor(accent)
                                    .padding(.bottom, 8)
                            }
                            .frame(width: keyW, height: keyH)
                        } else {
                            Spacer().frame(width: keyW, height: keyH)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 1.2))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius * 1.2)
                    .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
            )
            .overlay(
                SimultaneousTouchGesture { events in
                    for event in events {
                        let loc = event.location
                        switch event.phase {
                        case .began:
                            let note = noteAt(loc, geo: geo)
                            touchToNote[event.id] = note
                            pressedKeys.insert(note)
                            let vel: Float = 0.8
                            engine.noteOn(touchID: event.id, note: note, velocity: vel,
                                          x: Float(loc.x / geo.size.width),
                                          y: Float(1 - loc.y / geo.size.height))
                        case .moved:
                            // Slide between keys
                            let note = noteAt(loc, geo: geo)
                            if let prev = touchToNote[event.id], prev != note {
                                engine.noteOff(touchID: event.id)
                                pressedKeys.remove(prev)
                                touchToNote[event.id] = note
                                pressedKeys.insert(note)
                                engine.noteOn(touchID: event.id, note: note, velocity: 0.8,
                                              x: Float(loc.x / geo.size.width),
                                              y: Float(1 - loc.y / geo.size.height))
                            }
                        default:
                            if let note = touchToNote[event.id] {
                                pressedKeys.remove(note)
                                touchToNote.removeValue(forKey: event.id)
                                engine.noteOff(touchID: event.id)
                            }
                        }
                    }
                }
            )
            .shadow(color: accent.opacity(0.15), radius: 10)
        }
    }

    // MARK: - Key views

    private func whiteKey(note: Int, width: CGFloat, height: CGFloat,
                           theme: AppTheme, accent: Color) -> some View {
        let pressed = pressedKeys.contains(note)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4)
                .fill(pressed
                      ? accent.opacity(0.35)
                      : (theme.id == "ivory" ? Color(hex: "#FAF6F0") : Color.white.opacity(0.95)))
                .padding(.horizontal, 1.5)
                .padding(.vertical, 1)
        }
        .frame(width: width, height: height)
        .overlay(
            Rectangle()
                .fill(theme.panelBorder.opacity(0.3))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
    }

    private func blackKey(note: Int, width: CGFloat, height: CGFloat,
                           theme: AppTheme, accent: Color) -> some View {
        let pressed = pressedKeys.contains(note)
        return RoundedRectangle(cornerRadius: 4)
            .fill(pressed
                  ? accent.opacity(0.7)
                  : Color(hex: theme.id == "ivory" ? "#1A1208" : "#0A0A0A"))
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
            )
    }

    // MARK: - Hit test

    private func noteAt(_ loc: CGPoint, geo: GeometryProxy) -> Int {
        let totalWhite = whiteNotes.count
        let keyW = geo.size.width / CGFloat(totalWhite)
        let keyH = geo.size.height
        let blackH = keyH * 0.60
        let blackW = keyW * 0.58

        // Check black keys first (they appear on top)
        for item in blackNotes {
            let x = keyW * CGFloat(item.afterWhiteIndex) + keyW - blackW * 0.5
            let rect = CGRect(x: x, y: 0, width: blackW, height: blackH)
            if rect.contains(loc) { return min(item.note, 127) }
        }

        // Fall back to white key
        let whiteIdx = min(Int(loc.x / keyW), whiteNotes.count - 1)
        return min(whiteNotes[max(0, whiteIdx)], 127)
    }

    private func midiToNoteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midi / 12) - 1
        return "\(names[midi % 12])\(octave)"
    }
}
