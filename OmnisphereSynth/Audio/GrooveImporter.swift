import Foundation

enum GrooveImporter {

    // MARK: - GM + EZdrummer 3 note → DrumVoiceID

    private static let noteMap: [Int: DrumVoiceID] = [
        // Kicks
        35: .kick,  36: .kick,

        // Snares (center, rimshot, ghost, rimclick, hand-clap)
        37: .snare, 38: .snare, 39: .snare, 40: .snare,

        // Hi-Hat closed (tip, edge, pedal, tambourine)
        42: .hihat, 44: .hihat, 54: .hihat,

        // Hi-Hat open
        46: .hihatOpen,

        // Ride (tip, bell, edge, cowbell) + Ride 2
        51: .rideBell, 53: .rideBell, 56: .rideBell, 59: .rideBell,

        // Crash (1, 2, china, splash, china2)
        49: .crash, 52: .crash, 55: .crash, 57: .crash, 58: .crash,

        // Tom Hi (EZD Tom1=48, Tom2=50, HiFloor=60, MuteHiConga=62)
        48: .tomHi, 50: .tomHi, 60: .tomHi, 62: .tomHi,

        // Tom Mid (LowMid=47, Low=45, OpenHiConga=63)
        45: .tomMid, 47: .tomMid, 63: .tomMid,

        // Tom Lo (LoFloor=41, HiFloor=43, LoConga=64, EZD LoFloor=65)
        41: .tomLo, 43: .tomLo, 64: .tomLo, 65: .tomLo,
    ]

    // MARK: - Bundle scan

    /// Scans the entire app bundle for .mid files, parses them, and returns DrumPatterns.
    /// Files may be at the bundle root (added individually) or in subdirectories
    /// (added as a folder reference). The recursive enumerator handles both.
    static func importFromBundle() -> [DrumPattern] {
        guard let enumerator = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var patterns: [DrumPattern] = []

        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "mid" || url.pathExtension.lowercased() == "midi" {
            guard let data    = try? Data(contentsOf: url),
                  let midi    = MidiParser.parse(data),
                  let pattern = convert(midi, url: url)
            else { continue }
            patterns.append(pattern)
        }

        print("GrooveImporter: \(patterns.count) MIDI groove(s) imported from bundle")
        return patterns
    }

    // MARK: - MIDI → DrumPattern

    private static func convert(_ midi: ParsedMidi, url: URL) -> DrumPattern? {
        guard midi.ticksPerBeat > 0 else { return nil }

        // Prefer channel 9 (GM drums = channel 10, 0-indexed = 9).
        // Fall back to all channels if the file isn't on channel 9 (e.g. some EZD exports).
        let drumNotes: [MidiNote] = {
            let ch9 = midi.notes.filter { $0.channel == 9 }
            return ch9.isEmpty ? midi.notes : ch9
        }()
        guard !drumNotes.isEmpty else { return nil }

        // Round up to the nearest 1/2/4/8-bar loop boundary
        let tpb         = midi.ticksPerBeat
        let ticksPerBar = tpb * 4
        let rawBars     = Double(midi.durationTicks) / Double(ticksPerBar)
        let bars        = rawBars <= 1 ? 1 : rawBars <= 2 ? 2 : rawBars <= 4 ? 4 : 8
        let loopMidi    = ticksPerBar * bars

        // Normalise to the app's internal resolution (9600 tpb)
        let targetTpb = 9600
        let scale     = Double(targetTpb) / Double(tpb)

        let hits: [DrumHit] = drumNotes.compactMap { n in
            guard let voice = noteMap[n.note] else { return nil }
            let scaledTick = Int32(Double(n.tick % loopMidi) * scale)
            return DrumHit(tick: scaledTick, voice: voice,
                           velocity: Float(n.velocity) / 127.0)
        }
        guard !hits.isEmpty else { return nil }

        let name      = url.deletingPathExtension().lastPathComponent
        let loopTicks = Int32(Double(loopMidi) * scale)
        let feel      = classifyFeel(name: name, pathHint: url.path, hits: hits)

        return DrumPattern(
            name:         name,
            feel:         feel,
            loopTicks:    loopTicks,
            ticksPerBeat: Int32(targetTpb),
            hits:         hits.sorted { $0.tick < $1.tick }
        )
    }

    // MARK: - Feel classification

    private static func classifyFeel(name: String, pathHint: String, hits: [DrumHit]) -> DrumFeel {
        let lower = "\(name) \(pathHint)".lowercased()

        // Keyword pass — EZdrummer directory/file names are descriptive
        if lower.contains("ghost")                                          { return .ghost  }
        if lower.contains("halftime") || lower.contains("half time")
        || lower.contains("half-time") || lower.contains("slow")
        || lower.contains("ballad")                                         { return .pulse  }
        if lower.contains("ride")                                           { return .ride   }
        if lower.contains("crash")                                          { return .crash  }
        if lower.contains("fill") || lower.contains("tom")                  { return .toms   }
        if lower.contains("hihat") || lower.contains("hi-hat")
        || lower.contains("hat groove")                                     { return .hihat  }
        if lower.contains("build") || lower.contains("double bass")
        || lower.contains("heavy") || lower.contains("chorus")             { return .build  }

        // Content pass — classify by which voices dominate
        let total = hits.count
        guard total > 0 else { return .pulse }

        func ratio(_ voices: DrumVoiceID...) -> Double {
            Double(hits.filter { voices.contains($0.voice) }.count) / Double(total)
        }

        if ratio(.rideBell)                 > 0.15 { return .ride   }
        if ratio(.crash)                    > 0.10 { return .crash  }
        if ratio(.tomHi, .tomMid, .tomLo)  > 0.20 { return .toms   }
        if ratio(.hihat, .hihatOpen)        > 0.35 { return .hihat  }
        if total < 16                               { return .ghost  }
        if total > 48                               { return .build  }
        return .pulse
    }
}
