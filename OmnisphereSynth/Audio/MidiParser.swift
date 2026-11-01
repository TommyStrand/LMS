import Foundation

struct MidiNote {
    let tick:     Int
    let channel:  Int
    let note:     Int       // 0-127
    let velocity: Int       // 1-127
}

struct ParsedMidi {
    let ticksPerBeat:  Int
    /// Loop length in raw MIDI ticks: the latest End-of-Track marker, or the last
    /// note-on if that's later. (The last note alone made a 2-bar groove with an
    /// empty or sparse second bar import as a 1-bar loop.)
    let durationTicks: Int
    let notes:         [MidiNote]
}

enum MidiParser {

    static func parse(_ data: Data) -> ParsedMidi? {
        var pos = data.startIndex

        // MARK: Helpers

        func readByte() -> UInt8? {
            guard pos < data.endIndex else { return nil }
            defer { pos = data.index(after: pos) }
            return data[pos]
        }
        func readU16() -> UInt16? {
            guard let hi = readByte(), let lo = readByte() else { return nil }
            return (UInt16(hi) << 8) | UInt16(lo)
        }
        func readU32() -> UInt32? {
            guard let hi = readU16(), let lo = readU16() else { return nil }
            return (UInt32(hi) << 16) | UInt32(lo)
        }
        func readVLQ() -> Int? {
            var value = 0
            for _ in 0..<4 {
                guard let b = readByte() else { return nil }
                value = (value << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { return value }
            }
            return nil
        }
        func skip(_ n: Int) {
            pos = data.index(pos, offsetBy: max(0, n), limitedBy: data.endIndex) ?? data.endIndex
        }
        func readTag() -> String? {
            guard data.index(pos, offsetBy: 4, limitedBy: data.endIndex) != nil else { return nil }
            let tag = String(bytes: data[pos..<data.index(pos, offsetBy: 4)], encoding: .ascii)
            skip(4)
            return tag
        }

        // MARK: Header

        guard readTag() == "MThd",
              let hlen = readU32(), hlen >= 6,
              let _   = readU16(),              // format (0/1/2 — we accept all)
              let nTrk = readU16(),
              let div  = readU16(),
              div & 0x8000 == 0                 // ticks-per-beat mode (not SMPTE)
        else { return nil }
        skip(Int(hlen) - 6)                     // tolerate an extended header

        let tpb = Int(div)
        var allNotes: [MidiNote] = []
        var maxTick = 0
        var endTick = 0

        // MARK: Tracks

        var tracksRead = 0
        while tracksRead < Int(nTrk), let tag = readTag(), let tlen = readU32() {
            let trackEnd = data.index(pos, offsetBy: Int(tlen), limitedBy: data.endIndex) ?? data.endIndex
            // Skip non-track chunks (e.g. Yamaha XF data) instead of aborting the file.
            guard tag == "MTrk" else { pos = trackEnd; continue }
            tracksRead += 1
            var absTick  = 0
            var running: UInt8 = 0

            while pos < trackEnd {
                guard let delta = readVLQ() else { break }
                absTick += delta

                guard pos < trackEnd else { break }
                var status = data[pos]

                if status < 0x80 {
                    // Running status: data[pos] is the first data byte — do not advance.
                    // If no status byte was ever seen, the track is malformed; stop here
                    // rather than desyncing the parser for the rest of the track.
                    guard running >= 0x80 else { break }
                    status = running
                } else {
                    running = status
                    skip(1)
                }

                let cmd = status & 0xF0
                let ch  = Int(status & 0x0F)

                switch cmd {
                case 0x80:                          // Note Off
                    skip(2)

                case 0x90:                          // Note On
                    guard let note = readByte(), let vel = readByte() else { break }
                    if vel > 0 {
                        allNotes.append(MidiNote(tick: absTick, channel: ch,
                                                  note: Int(note), velocity: Int(vel)))
                        maxTick = max(maxTick, absTick)
                    }

                case 0xA0, 0xB0, 0xE0:             // Aftertouch / CC / Pitch Bend
                    skip(2)

                case 0xC0, 0xD0:                   // Program Change / Channel Pressure
                    skip(1)

                case 0xF0:
                    if status == 0xFF {             // Meta event
                        let metaType = readByte() ?? 0
                        if let mlen = readVLQ() { skip(mlen) }
                        if metaType == 0x2F {           // end-of-track: marks the length
                            endTick = max(endTick, absTick)
                            pos = trackEnd
                        }
                    } else {                        // SysEx
                        if let slen = readVLQ() { skip(slen) }
                    }

                default:
                    break
                }
            }

            pos = trackEnd
        }

        guard !allNotes.isEmpty else { return nil }
        return ParsedMidi(ticksPerBeat: tpb, durationTicks: max(maxTick, endTick), notes: allNotes)
    }
}
