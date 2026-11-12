import MediaPlayer
import FonaCore

/// Play/pause key, headphone buttons and Control Center (user request 2026-11-12). macOS sends the media key to the
/// app that last published Now Playing info, so Fona publishes station + title while it plays.
@MainActor
enum NowPlaying {
    static func start(_ model: AppModel) {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak model] _ in
            FileLog.shared.write("media key play/pause"); model?.togglePlay(); return .success
        }
        c.playCommand.addTarget { [weak model] _ in
            guard let model, !model.isPlaying, model.current != nil else { return .commandFailed }
            FileLog.shared.write("media key play"); model.togglePlay(); return .success
        }
        c.pauseCommand.addTarget { [weak model] _ in
            guard let model, model.isPlaying else { return .commandFailed }
            FileLog.shared.write("media key pause"); model.togglePlay(); return .success
        }
    }

    static func update(_ model: AppModel) {
        let center = MPNowPlayingInfoCenter.default()
        guard let s = model.current else { center.nowPlayingInfo = nil; center.playbackState = .stopped; return }
        // title is the already sanitized ICY text, the same string the popover shows
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: model.title.isEmpty ? s.displayName : model.title,
                                 MPMediaItemPropertyArtist: s.displayName,
                                 MPNowPlayingInfoPropertyIsLiveStream: true,
                                 MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        center.playbackState = model.isPlaying ? .playing : .paused
    }
}
