import AVFoundation
import MediaPlayer

// Manages MPNowPlayingInfoCenter and MPRemoteCommandCenter for AirPlay 2.
// Remote command events are forwarded via NotificationCenter so this class
// needs no direct reference to the engine or view layer.
final class NowPlayingManager {

    static let shared = NowPlayingManager()

    private init() {
        configureRemoteCommands()
    }

    // MARK: - Now Playing info

    func update(presetName: String, isLiveInstrument: Bool = true, isPlaying: Bool = false) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:              presetName,
            MPMediaItemPropertyArtist:             "SuperNovaPad",
            MPMediaItemPropertyAlbumTitle:         "Touch Synthesizer",
            MPNowPlayingInfoPropertyIsLiveStream:  isLiveInstrument,
            MPNowPlayingInfoPropertyPlaybackRate:  isPlaying ? 1.0 : 0.0,
        ]
        if !isLiveInstrument {
            info[MPMediaItemPropertyPlaybackDuration] = 0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setPlaybackState(_ isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote commands

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled  = true
        c.pauseCommand.isEnabled = true
        c.stopCommand.isEnabled  = true
        c.togglePlayPauseCommand.isEnabled = true

        // Drum machine is the only component with a discrete play/pause state
        c.playCommand.addTarget  { _ in NotificationCenter.default.post(name: .remotePlay,   object: nil); return .success }
        c.pauseCommand.addTarget { _ in NotificationCenter.default.post(name: .remotePause,  object: nil); return .success }
        c.stopCommand.addTarget  { _ in NotificationCenter.default.post(name: .remotePause,  object: nil); return .success }
        c.togglePlayPauseCommand.addTarget { _ in NotificationCenter.default.post(name: .remoteToggle, object: nil); return .success }

        // Disable seek / track-skip — not applicable to a live instrument
        c.nextTrackCommand.isEnabled            = false
        c.previousTrackCommand.isEnabled        = false
        c.changePlaybackPositionCommand.isEnabled = false
        c.skipForwardCommand.isEnabled          = false
        c.skipBackwardCommand.isEnabled         = false
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let remotePlay   = Notification.Name("SNP.remotePlay")
    static let remotePause  = Notification.Name("SNP.remotePause")
    static let remoteToggle = Notification.Name("SNP.remoteToggle")
}
