import AVFoundation
import Foundation
import Observation

@Observable
final class AudioRecorder {
    var isRecording  = false
    var isExporting  = false
    var exportURL: URL?
    var failed       = false

    // Internal plumbing — written from the tap/write queue, so kept out of
    // observation tracking.
    @ObservationIgnored private var synthTempURL: URL?
    @ObservationIgnored private var drumTempURL:  URL?
    @ObservationIgnored private var synthFile: AVAudioFile?
    @ObservationIgnored private var drumFile:  AVAudioFile?
    @ObservationIgnored private weak var synthAVEngine: AVAudioEngine?
    @ObservationIgnored private weak var drumAVEngine:  AVAudioEngine?

    // Serial queue so tap callbacks never race with file closure
    private let writeQueue = DispatchQueue(label: "audio.recorder.write", qos: .userInteractive)

    func startRecording(synthEngine: AVAudioEngine, drumEngine: AVAudioEngine) {
        guard !isRecording else { return }
        exportURL = nil
        failed    = false

        let stamp    = Int(Date().timeIntervalSince1970)
        let synthURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jam_synth_\(stamp).caf")
        let drumURL  = FileManager.default.temporaryDirectory
            .appendingPathComponent("jam_drum_\(stamp).caf")

        // CAF with 16-bit PCM — readable by AVMutableComposition on all OS versions
        let recSettings: [String: Any] = [
            AVFormatIDKey:              Int(kAudioFormatLinearPCM),
            AVSampleRateKey:            44100.0,
            AVNumberOfChannelsKey:      2,
            AVLinearPCMBitDepthKey:     16,
            AVLinearPCMIsFloatKey:      false,
            AVLinearPCMIsBigEndianKey:  false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            synthFile = try AVAudioFile(forWriting: synthURL, settings: recSettings)
            drumFile  = try AVAudioFile(forWriting: drumURL,  settings: recSettings)
        } catch {
            print("AudioRecorder: file creation failed – \(error)")
            DispatchQueue.main.async { self.failed = true }
            return
        }

        synthTempURL       = synthURL
        drumTempURL        = drumURL
        self.synthAVEngine = synthEngine
        self.drumAVEngine  = drumEngine

        let synthFmt = synthEngine.mainMixerNode.outputFormat(forBus: 0)
        let drumFmt  = drumEngine.mainMixerNode.outputFormat(forBus: 0)

        synthEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: synthFmt) { [weak self] buf, _ in
            self?.writeQueue.async { try? self?.synthFile?.write(from: buf) }
        }
        drumEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: drumFmt) { [weak self] buf, _ in
            self?.writeQueue.async { try? self?.drumFile?.write(from: buf) }
        }

        DispatchQueue.main.async { self.isRecording = true }
    }

    func stopRecording() {
        guard isRecording else { return }

        synthAVEngine?.mainMixerNode.removeTap(onBus: 0)
        drumAVEngine?.mainMixerNode.removeTap(onBus: 0)

        // Flush and close files before handing URLs to AVAsset
        writeQueue.sync {
            self.synthFile = nil
            self.drumFile  = nil
        }

        DispatchQueue.main.async { self.isRecording = false; self.isExporting = true }
        Task { await exportMix() }
    }

    // MARK: - Export

    @MainActor
    private func exportMix() async {
        guard let synthURL = synthTempURL, let drumURL = drumTempURL else {
            isExporting = false; failed = true; return
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Jam \(formattedDate()).m4a")

        let composition = AVMutableComposition()
        let synthAsset  = AVURLAsset(url: synthURL)
        let drumAsset   = AVURLAsset(url: drumURL)

        do {
            let synthTracks   = try await synthAsset.loadTracks(withMediaType: .audio)
            let synthDuration = try await synthAsset.load(.duration)
            if let src = synthTracks.first,
               let trk = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                try trk.insertTimeRange(CMTimeRange(start: .zero, duration: synthDuration),
                                        of: src, at: .zero)
            }

            let drumTracks   = try await drumAsset.loadTracks(withMediaType: .audio)
            let drumDuration = try await drumAsset.load(.duration)
            if let src = drumTracks.first,
               let trk = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                try trk.insertTimeRange(CMTimeRange(start: .zero, duration: drumDuration),
                                        of: src, at: .zero)
            }
        } catch {
            print("AudioRecorder: composition failed – \(error)")
            isExporting = false; failed = true; return
        }

        guard let session = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetAppleM4A) else {
            isExporting = false; failed = true; return
        }

        session.outputURL      = outURL
        session.outputFileType = .m4a

        await session.export()

        isExporting = false
        if session.status == .completed {
            exportURL = outURL
            try? FileManager.default.removeItem(at: synthURL)
            try? FileManager.default.removeItem(at: drumURL)
        } else {
            print("AudioRecorder: export failed – \(session.error?.localizedDescription ?? "unknown")")
            failed = true
        }
    }

    private func formattedDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH·mm·ss"
        return f.string(from: Date())
    }
}
