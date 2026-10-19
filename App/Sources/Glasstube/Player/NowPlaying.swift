import AppKit
import MediaPlayer

/// "Ahora suena" del Centro de control y teclas multimedia (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`).
/// En SmartTube esto lo hacía el `BackgroundPlaybackService`; en macOS basta con publicar el estado.
final class NowPlayingController {
    private weak var player: PlayerModel?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkVideoId: String?

    func attach(to player: PlayerModel) {
        self.player = player
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        // Los manejadores pueden llegar fuera del hilo principal: se pasa al actor principal.
        add(center.togglePlayPauseCommand) { $0.togglePause() }
        add(center.playCommand) { $0.play() }
        add(center.pauseCommand) { $0.pause() }
        add(center.nextTrackCommand) { $0.playNext() }
        add(center.previousTrackCommand) { $0.playPrevious() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { $0.seek(by: 10) }
        add(center.skipBackwardCommand) { $0.seek(by: -10) }
        let token = center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.player?.seek(to: time) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, token))
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (PlayerModel) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let player = self?.player else { return }
                action(player)
            }
            return .success
        }
        targets.append((command, token))
    }

    func update(_ player: PlayerModel) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? (player.status?.rate ?? 1) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: player.item.isLive,
        ]
        if let author = player.author { info[MPMediaItemPropertyArtist] = author }
        if let duration = player.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        let center = MPNowPlayingInfoCenter.default()
        if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork], artworkVideoId == player.item.videoId {
            info[MPMediaItemPropertyArtwork] = existing
        }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
        loadArtwork(for: player)
    }

    func updateElapsed(_ player: PlayerModel) {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return update(player) }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? (player.status?.rate ?? 1) : 0
        center.nowPlayingInfo = info
    }

    private func loadArtwork(for player: PlayerModel) {
        let item = player.item
        guard artworkVideoId != item.videoId else { return }
        artworkVideoId = item.videoId
        Task {
            guard let image = await ImagePipeline.shared.firstImage(from: MediaItemImages.card(item, width: 640)),
                  self.artworkVideoId == item.videoId else { return }
            let artworkImage = image
            // MediaPlayer pide la imagen desde su propia cola: el cierre no puede quedar aislado al actor principal.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in artworkImage }
            let center = MPNowPlayingInfoCenter.default()
            var info = center.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            center.nowPlayingInfo = info
        }
    }

    func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        for (command, token) in targets { command.removeTarget(token) }
        targets = []
        artworkVideoId = nil
    }
}
