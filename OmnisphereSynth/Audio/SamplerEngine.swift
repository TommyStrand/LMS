import AVFoundation

/// Wraps one AVAudioUnitSampler loaded from synthesised WAV samples.
/// Pitch-shifting between root notes is handled by the sampler itself.
final class SamplerEngine {

    let samplerNode = AVAudioUnitSampler()
    private let instrument: SamplerInstrument

    init(instrument: SamplerInstrument) {
        self.instrument = instrument
    }

    // MARK: - Load

    func load() {
        guard let presetURL = buildPreset() else {
            print("SamplerEngine[\(instrument.id)]: no samples found in bundle")
            return
        }
        do {
            try samplerNode.loadInstrument(at: presetURL)
        } catch {
            print("SamplerEngine[\(instrument.id)]: loadInstrument failed – \(error)")
        }
    }

    // MARK: - Playback

    func noteOn(_ note: UInt8, velocity: UInt8) {
        samplerNode.startNote(note, withVelocity: velocity, onChannel: 0)
    }

    func noteOff(_ note: UInt8) {
        samplerNode.stopNote(note, onChannel: 0)
    }

    // MARK: - AUPreset generation

    private func buildPreset() -> URL? {
        let rootNotes = instrument.rootNotes
        guard !rootNotes.isEmpty else { return nil }

        var zones: [String] = []
        var zoneID = 0

        for layer in instrument.velocityLayers {
            for (i, root) in rootNotes.enumerated() {
                // Each root note covers from the midpoint with the previous root
                // down to the midpoint with the next root.
                let lo = i == 0 ? 0 : (root + rootNotes[i - 1] + 1) / 2
                let hi = i == rootNotes.count - 1 ? 127 : (root + rootNotes[i + 1]) / 2

                let filename = "\(root)_\(layer.midiValue)"
                guard let url = Bundle.main.url(
                    forResource: filename, withExtension: "wav",
                    subdirectory: "Samples/\(instrument.id)"
                ) else { continue }

                zones.append(zone(
                    id: zoneID, fileURL: url,
                    root: root, lo: lo, hi: hi,
                    loVel: layer.loVel, hiVel: layer.hiVel
                ))
                zoneID += 1
            }
        }

        guard !zones.isEmpty else { return nil }

        let xml = auPresetXML(name: instrument.displayName, zones: zones)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(instrument.id).aupreset")
        do {
            try xml.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("SamplerEngine: failed to write preset – \(error)")
            return nil
        }
    }

    private func zone(id: Int, fileURL: URL,
                      root: Int, lo: Int, hi: Int,
                      loVel: Int, hiVel: Int) -> String {
        """
                    <dict>
                        <key>ID</key><integer>\(id)</integer>
                        <key>Wave File URL</key><string>\(fileURL.absoluteString)</string>
                        <key>Root Note</key><integer>\(root)</integer>
                        <key>Lo Note</key><integer>\(lo)</integer>
                        <key>Hi Note</key><integer>\(hi)</integer>
                        <key>Lo Velocity</key><integer>\(loVel)</integer>
                        <key>Hi Velocity</key><integer>\(hiVel)</integer>
                        <key>enabled</key><true/>
                        <key>Loop Enabled</key><false/>
                        <key>Pitch Tracking</key><true/>
                    </dict>
        """
    }

    private func auPresetXML(name: String, zones: [String]) -> String {
        let zonesJoined = zones.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AU version</key>
            <real>1</real>
            <key>Instrument</key>
            <dict>
                <key>Layers</key>
                <array>
                    <dict>
                        <key>Amplifier</key>
                        <dict>
                            <key>ID</key><integer>0</integer>
                            <key>enabled</key><true/>
                        </dict>
                        <key>Connections</key><array/>
                        <key>Envelopes</key><array/>
                        <key>Events</key><array/>
                        <key>Filters</key><array/>
                        <key>ID</key><integer>0</integer>
                        <key>LFOs</key><array/>
                        <key>Modulators</key><array/>
                        <key>Zones</key>
                        <array>
        \(zonesJoined)
                        </array>
                    </dict>
                </array>
                <key>name</key><string>\(name)</string>
            </dict>
            <key>name</key><string>\(name)</string>
            <key>subtype</key><integer>1935764848</integer>
            <key>manufacturer</key><integer>1634758764</integer>
            <key>type</key><integer>1635085685</integer>
            <key>version</key><integer>0</integer>
        </dict>
        </plist>
        """
    }
}
