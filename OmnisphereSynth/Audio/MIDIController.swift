import CoreMIDI
import Foundation

// MIDI input bridge. Auto-connects to every available MIDI source and
// translates Note On/Off, mod wheel, sustain pedal and the eight MPK Mini
// Plus default knobs (CC70-77) into engine calls.
final class MIDIController: ObservableObject {

    @Published private(set) var connectedDeviceNames: [String] = []
    @Published private(set) var lastNote: Int? = nil
    @Published private(set) var lastNoteVelocity: Float = 0
    @Published private(set) var activityPulse: Int = 0   // increments on every note

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private weak var engine: AudioEngine?

    // Per-note state
    private var midiNoteIDs: [Int: Int] = [:]
    private var sustainHeld = false
    private var sustainedNotes: Set<Int> = []
    private let touchIDBase = 0x10000

    init(engine: AudioEngine) {
        self.engine = engine
        setup()
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client   != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Setup

    private func setup() {
        let clientName = "SuperNovaPad" as CFString
        var status = MIDIClientCreateWithBlock(clientName, &client) { [weak self] _ in
            // Re-scan whenever a device is plugged in or removed.
            DispatchQueue.main.async { self?.connectAllSources() }
        }
        guard status == noErr else {
            print("MIDI: client create failed (\(status))")
            return
        }

        let portName = "Input" as CFString
        status = MIDIInputPortCreateWithProtocol(client, portName, ._1_0, &inputPort) {
            [weak self] eventListPtr, _ in
            self?.handleEventList(eventListPtr)
        }
        guard status == noErr else {
            print("MIDI: port create failed (\(status))")
            return
        }

        connectAllSources()
    }

    private func connectAllSources() {
        let n = MIDIGetNumberOfSources()
        var names: [String] = []
        for i in 0..<n {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(inputPort, src, nil)
            var nameRef: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &nameRef) == noErr,
               let cf = nameRef?.takeRetainedValue() {
                names.append(cf as String)
            } else {
                names.append("MIDI Source \(i + 1)")
            }
        }
        connectedDeviceNames = names
    }

    // MARK: - Event parsing

    private func handleEventList(_ listPtr: UnsafePointer<MIDIEventList>) {
        let numPackets = Int(listPtr.pointee.numPackets)
        guard numPackets > 0 else { return }

        let firstOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet) ?? 12
        var pktPtr = UnsafeMutableRawPointer(mutating: listPtr)
            .advanced(by: firstOffset)
            .assumingMemoryBound(to: MIDIEventPacket.self)

        for _ in 0..<numPackets {
            handleEventPacket(pktPtr)
            pktPtr = MIDIEventPacketNext(pktPtr)
        }
    }

    private func handleEventPacket(_ ptr: UnsafePointer<MIDIEventPacket>) {
        let count = Int(ptr.pointee.wordCount)
        guard count > 0 else { return }
        // MIDIEventPacket is variable-length: the real word array extends past the
        // fixed 64-word `words` tuple in the struct declaration. Read directly from
        // the packet's memory (valid for `wordCount` words) rather than from a value
        // copy of `pkt`, whose tuple only covers the first 64 words.
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) ?? 12
        let words = UnsafeRawPointer(ptr).advanced(by: wordsOffset)
            .assumingMemoryBound(to: UInt32.self)
        var i = 0
        while i < count {
            let word = words[i]
            let mt = (word >> 28) & 0xF
            switch mt {
            case 0, 1:
                i += 1
            case 2:
                // MIDI 1.0 Channel Voice (1 word)
                let status = UInt8((word >> 16) & 0xFF)
                let d1     = UInt8((word >>  8) & 0xFF)
                let d2     = UInt8( word        & 0xFF)
                handleMIDI1(status: status, d1: d1, d2: d2)
                i += 1
            case 3, 5:
                i += 2
            case 4:
                // MIDI 2.0 CV (2 words) — translate the parts we care about
                if i + 1 < count {
                    handleMIDI2(word0: word, word1: words[i + 1])
                }
                i += 2
            default:
                i += 1
            }
        }
    }

    private func handleMIDI1(status: UInt8, d1: UInt8, d2: UInt8) {
        let cmd = status & 0xF0
        switch cmd {
        case 0x90:
            if d2 > 0 { dispatchNoteOn(Int(d1), velocity: Float(d2) / 127) }
            else      { dispatchNoteOff(Int(d1)) }
        case 0x80:
            dispatchNoteOff(Int(d1))
        case 0xB0:
            dispatchCC(cc: d1, value: d2)
        default:
            break
        }
    }

    private func handleMIDI2(word0: UInt32, word1: UInt32) {
        // MIDI 2.0 channel voice: status byte in low byte of word0 high half
        let status = UInt8((word0 >> 16) & 0xF0)
        let d1     = UInt8((word0 >>  8) & 0x7F)
        // 16-bit velocity / value lives in the high half of word1
        let v16    = UInt32(word1 >> 16) & 0xFFFF
        let asNorm = Float(v16) / 65535
        switch status {
        case 0x90:
            if v16 > 0 { dispatchNoteOn(Int(d1), velocity: asNorm) }
            else       { dispatchNoteOff(Int(d1)) }
        case 0x80:
            dispatchNoteOff(Int(d1))
        case 0xB0:
            dispatchCC(cc: d1, value: UInt8(min(127, Int(asNorm * 127))))
        default:
            break
        }
    }

    // MARK: - Engine dispatch (must hop to main)

    private func dispatchNoteOn(_ note: Int, velocity: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            // If the same note is already ringing (held & retriggered), end it.
            if let prev = self.midiNoteIDs[note] {
                engine.noteOff(touchID: prev)
            }
            let id = self.touchIDBase + note
            engine.noteOn(touchID: id, note: note, velocity: max(0.05, velocity),
                          x: 0.5, y: 0.5)
            self.midiNoteIDs[note]    = id
            self.lastNote             = note
            self.lastNoteVelocity     = velocity
            self.activityPulse       &+= 1
        }
    }

    private func dispatchNoteOff(_ note: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.sustainHeld {
                self.sustainedNotes.insert(note)
                return
            }
            if let id = self.midiNoteIDs.removeValue(forKey: note) {
                self.engine?.noteOff(touchID: id)
            }
        }
    }

    private func dispatchCC(cc: UInt8, value: UInt8) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            let v = Float(value) / 127
            switch cc {
            case 1:   // Mod wheel → Y-axis modulation on every active MIDI voice
                for (note, id) in self.midiNoteIDs {
                    engine.updateTouch(touchID: id, x: 0.5, y: v)
                    _ = note
                }
            case 64:  // Sustain pedal
                let on = value >= 64
                if on {
                    self.sustainHeld = true
                } else {
                    self.sustainHeld = false
                    for note in self.sustainedNotes {
                        if let id = self.midiNoteIDs.removeValue(forKey: note) {
                            engine.noteOff(touchID: id)
                        }
                    }
                    self.sustainedNotes.removeAll()
                }

            // MPK Mini Plus default knob CCs (Bank A, K1–K8)
            case 70: engine.setReverb(v)
            case 71: engine.setDelay(v)
            case 72: engine.setTremolo(v)
            case 73: engine.setChorus(v)
            case 74: engine.setDistortion(v)
            case 75: engine.setShimmer(v)
            case 76: engine.setGrit(v)
            case 77: engine.setLofi(v)

            default: break
            }
        }
    }

    // MARK: - Public

    var isConnected: Bool { !connectedDeviceNames.isEmpty }
    var primaryDeviceName: String? { connectedDeviceNames.first }
}
