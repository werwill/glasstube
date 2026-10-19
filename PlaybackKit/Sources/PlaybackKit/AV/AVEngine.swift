import AppKit
import AVFoundation

/// Motor mínimo con AVPlayer para directos: YouTube los entrega en HLS (VISIONOS trae un manifiesto válido, según la
/// fase 0) y AVPlayer los reproduce sin ayuda, con decodificación por hardware, AirPlay y el PiP del sistema más
/// adelante. Solo `.url` (HLS o un archivo); `.streamed` (SABR) es cosa de `MPVEngine`.
///
/// Calidad: AVPlayer elige la variante del HLS por sí mismo. Las «pistas de video» son Auto más las variantes del
/// manifiesto maestro; elegir una fija `preferredMaximumResolution` y `preferredPeakBitRate` (un tope, no una variante
/// exacta: es lo que AVFoundation permite).
@MainActor
public final class AVEngine: PlayerEngine {
    public let kind = PlayerEngineKind.avPlayer
    public let status = PlayerStatus()
    public var videoView: NSView { surface }
    /// La capa de AVPlayer (para el PiP del sistema, `makePictureInPicture()`).
    var playerLayer: AVPlayerLayer { surface.playerLayer }

    private let player = AVPlayer()
    private let surface: AVPlayerSurface
    private let hub = EventHub()
    private var item: PlaybackItem?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var variants: [HLSVariant] = []
    private var selectedVariant: HLSVariant?
    private var userPaused = false
    private var failure: PlayerError?

    struct HLSVariant: Equatable {
        let bandwidth: Int
        let width: Int?
        let height: Int?
        let fps: Double?
        let codecs: String?
    }

    public init() {
        surface = AVPlayerSurface(player: player)
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateState() } }
        })
        observations.append(player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = Double(player.rate)
            DispatchQueue.main.async { MainActor.assumeIsolated { if rate > 0 { self?.status.rate = rate } } }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    public func events() -> AsyncStream<PlayerEvent> { hub.stream() }

    public func load(_ item: PlaybackItem) async throws {
        guard case .url(let url, let audio, let headers) = item.source else {
            throw PlayerError("AVEngine solo reproduce URLs (HLS o archivos); SABR va con MPVEngine")
        }
        if audio != nil { note("AVEngine no admite audio aparte: se ignora") }
        self.item = item
        failure = nil
        userPaused = false
        variants = []
        selectedVariant = nil
        status.state = .loading
        hub.send(.state(.loading))
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        observeItem(playerItem)
        player.replaceCurrentItem(with: playerItem)
        if item.startPosition > 0, !item.isLive {
            await player.seek(to: CMTime(seconds: item.startPosition, preferredTimescale: 600))
        }
        player.play()
        // Variantes del manifiesto maestro (para elegir calidad) y pistas de audio y subtítulos del asset.
        Task { [weak self] in await self?.loadVariants(url: url, headers: headers) }
        Task { [weak self] in await self?.loadMediaSelections(asset) }
    }

    public func play() {
        userPaused = false
        player.play()
        updateState()
    }

    public func pause() {
        userPaused = true
        player.pause()
        updateState()
    }

    public func togglePause() {
        if userPaused || player.timeControlStatus == .paused { play() } else { pause() }
    }

    public func seek(to seconds: Double, mode: SeekMode) async {
        guard let current = player.currentItem else { return }
        var target = seconds
        if let range = current.seekableTimeRanges.last?.timeRangeValue, range.duration.seconds.isFinite {
            target = min(max(seconds, range.start.seconds), range.end.seconds)
        }
        let tolerance = mode == .exact ? CMTime.zero : CMTime.positiveInfinity
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        status.position = player.currentTime().seconds
        hub.send(.seekCompleted(position: status.position))
    }

    public func setRate(_ rate: Double) {
        player.defaultRate = Float(rate)
        if player.rate > 0 { player.rate = Float(rate) }
        status.rate = rate
    }

    public func setVolume(_ volume: Double) {
        player.volume = Float(max(0, min(1, volume)))
        status.volume = Double(player.volume)
    }

    public func setMuted(_ muted: Bool) {
        player.isMuted = muted
        status.isMuted = muted
    }

    public func select(track: MediaTrack) async throws {
        guard let current = player.currentItem else { return }
        switch track.kind {
        case .video:
            let variant = track.id == "hls:auto" ? nil : variants.first { Self.trackID($0) == track.id }
            selectedVariant = variant
            current.preferredMaximumResolution = variant.flatMap { v in v.width.map { CGSize(width: $0, height: v.height ?? 0) } } ?? .zero
            current.preferredPeakBitRate = Double(variant?.bandwidth ?? 0)
            publishVariants()
        case .audio, .subtitle:
            let characteristic: AVMediaCharacteristic = track.kind == .audio ? .audible : .legible
            guard let group = try await current.asset.loadMediaSelectionGroup(for: characteristic),
                  let index = Int(track.id.split(separator: ":").last ?? ""), group.options.indices.contains(index) else { return }
            current.select(group.options[index], in: group)
            await loadMediaSelections(current.asset)
        }
    }

    public func disableSubtitles() {
        guard let current = player.currentItem else { return }
        Task {
            if let group = try? await current.asset.loadMediaSelectionGroup(for: .legible) { current.select(nil, in: group) }
            await loadMediaSelections(current.asset)
        }
    }

    public func addSubtitle(url: URL, language: String?, title: String?) async throws {
        throw PlayerError("AVEngine no admite subtítulos externos (en directos YouTube los da dentro del HLS)", recoverable: true)
    }

    public func stop() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        clearItemObservers()
        updateState()
    }

    public func shutdown() async {
        await stop()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        hub.finish()
    }

    // MARK: - Estado

    private func observeItem(_ playerItem: AVPlayerItem) {
        clearItemObservers()
        observations.append(playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed ? (item.error?.localizedDescription ?? "AVPlayerItem falló") : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failed { self?.fail(failed) } else { self?.updateState() }
                }
            }
        })
        itemObservers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateState(ended: true) }
        })
        itemObservers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: playerItem, queue: .main) { [weak self] notification in
            let entry = (notification.object as? AVPlayerItem)?.errorLog()?.events.last
            MainActor.assumeIsolated {
                if let entry { self?.note("AVPlayer: \(entry.errorStatusCode) \(entry.errorComment ?? "")") }
            }
        })
    }

    private func clearItemObservers() {
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        // La primera observación es la de timeControlStatus y la segunda la de rate; las demás son del item.
        while observations.count > 2 { observations.removeLast().invalidate() }
    }

    private func tick(_ time: CMTime) {
        guard let current = player.currentItem else { return }
        status.position = time.seconds.isFinite ? time.seconds : 0
        let duration = current.duration.seconds
        status.duration = duration.isFinite && duration > 0 ? duration : nil
        hub.send(.time(position: status.position, duration: status.duration))
        let loaded = current.loadedTimeRanges.map { $0.timeRangeValue }.map { $0.start.seconds...($0.start.seconds + $0.duration.seconds) }
        let ahead = loaded.first { $0.contains(status.position) }.map { $0.upperBound - status.position }
        let buffer = BufferStatus(ahead: ahead, seekableRanges: loaded, isStalled: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        if buffer != status.buffer {
            status.buffer = buffer
            hub.send(.buffer(buffer))
        }
        // AVPlayer no dice qué decodificador usa (`hardwareDecoder` queda en nil); para H.264 en un Mac es VideoToolbox.
        if let event = current.accessLog()?.events.last, event.indicatedBitrate > 0 {
            let size = current.presentationSize
            status.videoDescription = String(format: "HLS %.0fx%.0f · %.1f Mb/s", size.width, size.height, event.indicatedBitrate / 1_000_000)
            status.droppedFrames = max(0, event.numberOfDroppedVideoFrames)
        }
    }

    private func updateState(ended: Bool = false) {
        let state: PlaybackState
        if let failure {
            state = .failed(failure)
        } else if item == nil {
            state = .idle
        } else if ended {
            state = .ended
        } else if player.currentItem?.status != .readyToPlay {
            state = .loading
        } else if userPaused {
            state = .paused
        } else {
            switch player.timeControlStatus {
            case .playing: state = .playing
            case .waitingToPlayAtSpecifiedRate: state = .buffering
            case .paused: state = .paused
            @unknown default: state = .playing
            }
        }
        if state != status.state {
            status.state = state
            hub.send(.state(state))
        }
    }

    private func fail(_ message: String) {
        let error = PlayerError(message)
        failure = error
        hub.send(.error(error))
        updateState()
    }

    private func note(_ message: String) { hub.send(.note(message)) }

    // MARK: - Pistas

    private func loadVariants(url: URL, headers: [String: String]) async {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, _) = try? await URLSession.shared.data(for: request), let text = String(data: data, encoding: .utf8) else { return }
        variants = Self.parseVariants(text)
        publishVariants()
    }

    private func publishVariants() {
        var tracks = [MediaTrack(id: "hls:auto", kind: .video, title: "Auto", isSelected: selectedVariant == nil)]
        let unique = variants.reduce(into: [HLSVariant]()) { list, v in
            if !list.contains(where: { $0.height == v.height && $0.fps == v.fps }) { list.append(v) }
        }
        tracks += unique.sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) }.map { v in
            MediaTrack(id: Self.trackID(v), kind: .video, title: "\(v.height ?? 0)p\(v.fps.map { $0 > 30 ? String(format: "%.0f", $0) : "" } ?? "")",
                       codec: v.codecs, width: v.width, height: v.height, fps: v.fps, bitrate: v.bandwidth, isSelected: v == selectedVariant)
        }
        status.videoTracks = tracks
        hub.send(.tracks(status.videoTracks + status.audioTracks + status.subtitleTracks))
    }

    private func loadMediaSelections(_ asset: AVAsset) async {
        guard let current = player.currentItem else { return }
        var lists: [MediaTrackKind: [MediaTrack]] = [:]
        for (kind, characteristic) in [(MediaTrackKind.audio, AVMediaCharacteristic.audible), (.subtitle, .legible)] {
            guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            let selected = current.currentMediaSelection.selectedMediaOption(in: group)
            lists[kind] = group.options.enumerated().map { index, option in
                MediaTrack(id: "av:\(kind.rawValue):\(index)", kind: kind, title: option.displayName,
                           language: option.extendedLanguageTag ?? option.locale?.identifier, isSelected: option == selected)
            }
        }
        status.audioTracks = lists[.audio] ?? []
        status.subtitleTracks = lists[.subtitle] ?? []
        hub.send(.tracks(status.videoTracks + status.audioTracks + status.subtitleTracks))
    }

    static func trackID(_ v: HLSVariant) -> String { "hls:\(v.height ?? 0):\(v.bandwidth)" }

    /// `#EXT-X-STREAM-INF` del manifiesto maestro.
    static func parseVariants(_ text: String) -> [HLSVariant] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> HLSVariant? in
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { return nil }
            var attributes: [String: String] = [:]
            // Atributos separados por comas, con valores entre comillas que pueden llevar comas.
            let pattern = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#)
            let body = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let key = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body) else { continue }
                attributes[String(body[key])] = String(body[value]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init) else { return nil }
            let resolution = attributes["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
            return HLSVariant(bandwidth: bandwidth, width: resolution?.first, height: resolution?.last,
                              fps: attributes["FRAME-RATE"].flatMap(Double.init), codecs: attributes["CODECS"])
        }
    }
}

/// Vista con un AVPlayerLayer.
final class AVPlayerSurface: NSView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }
}
