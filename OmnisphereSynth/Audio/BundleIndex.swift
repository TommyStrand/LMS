import Foundation

/// One scan of the app bundle, shared by every loader.
///
/// Launch used to walk the whole bundle (~1000 WAVs) four separate times — the
/// drum kit, MIDI grooves, the sampler, and the pipe-organ preset check — all on
/// the main thread, which showed up as "System gesture gate timed out" and
/// dropped touch events at startup. `shared` is built once, thread-safely (Swift
/// lazy static), on first use, and is immutable afterwards, so it can be read
/// from background loading queues.
struct BundleIndex {
    /// "<parent folder>/<file name without extension>" → URL. Sampler lookups must
    /// be keyed by folder: every instrument uses the same {note}_{velocity}.wav names.
    let wavByFolderAndName: [String: URL]
    /// lowercased "<file name without extension>" → URL (drum-kit lookup; the kit's
    /// file names are unique).
    let wavByLowercasedName: [String: URL]
    /// Parent-folder names that contain at least one WAV.
    let foldersWithWavs: Set<String>
    /// .mid / .midi files anywhere in the bundle.
    let midiFiles: [URL]

    static let shared = BundleIndex(root: Bundle.main.bundleURL)

    init(root: URL) {
        var byFolder: [String: URL] = [:]
        var byName:   [String: URL] = [:]
        var folders = Set<String>()
        var midi: [URL] = []
        if let en = FileManager.default.enumerator(at: root,
                                                   includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                switch url.pathExtension.lowercased() {
                case "wav":
                    let folder = url.deletingLastPathComponent().lastPathComponent
                    let name   = url.deletingPathExtension().lastPathComponent
                    byFolder["\(folder)/\(name)"] = url
                    byName[name.lowercased()]     = url
                    folders.insert(folder)
                case "mid", "midi":
                    midi.append(url)
                default:
                    break
                }
            }
        }
        wavByFolderAndName  = byFolder
        wavByLowercasedName = byName
        foldersWithWavs     = folders
        midiFiles           = midi.sorted { $0.path < $1.path }
    }
}
