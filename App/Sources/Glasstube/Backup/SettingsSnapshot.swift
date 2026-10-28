import Foundation

/// Los ajustes que van en el respaldo: los de Interfaz, Reproductor, Subtítulos, SponsorBlock, DeArrow, el historial de la
/// cuenta y Spotlight. No van los que son de cada Mac (el nombre y la vinculación del control remoto, las
/// actualizaciones, el respaldo en iCloud Drive) ni el estado de la interfaz (pestañas abiertas). Todos opcionales: un
/// respaldo viejo o editado a mano cambia solo lo que trae.
nonisolated struct SettingsSnapshot: Codable, Equatable, Sendable {
    var appearance: String?
    var hoverPreviews: Bool?
    var showShortsOnHome: Bool?
    var controlsTimeout: Double?
    var maxHeight: Int?
    var codec: String?
    var buffer: Int?
    var resumePlayback: Bool?
    var autoplayNext: Bool?
    var autoplayCountdown: Double?
    var subtitlesByDefault: Bool?
    var subtitleLanguage: String?
    var sponsorBlockEnabled: Bool?
    var sponsorBlockAutoSkip: Bool?
    var deArrowEnabled: Bool?
    var deArrowTitles: Bool?
    var deArrowThumbnails: Bool?
    var showDislikes: Bool?
    var syncWatchHistory: Bool?
    var spotlightEnabled: Bool?

    /// Cuántos ajustes trae (el JSON omite los que faltan).
    var count: Int {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return object.count
    }
}

extension AppSettings {
    var snapshot: SettingsSnapshot {
        SettingsSnapshot(appearance: appearance.rawValue, hoverPreviews: hoverPreviews, showShortsOnHome: showShortsOnHome,
                         controlsTimeout: controlsTimeout, maxHeight: maxHeight, codec: codec.rawValue, buffer: buffer.rawValue,
                         resumePlayback: resumePlayback, autoplayNext: autoplayNext, autoplayCountdown: autoplayCountdown,
                         subtitlesByDefault: subtitlesByDefault, subtitleLanguage: subtitleLanguage,
                         sponsorBlockEnabled: sponsorBlockEnabled, sponsorBlockAutoSkip: sponsorBlockAutoSkip,
                         deArrowEnabled: deArrowEnabled, deArrowTitles: deArrowTitles, deArrowThumbnails: deArrowThumbnails,
                         showDislikes: showDislikes, syncWatchHistory: syncWatchHistory, spotlightEnabled: spotlightEnabled)
    }

    /// Pone los ajustes del respaldo (solo los que traiga y con valores válidos). Devuelve cuántos cambiaron.
    @discardableResult
    func apply(_ snapshot: SettingsSnapshot) -> Int {
        var changed = 0
        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value?) {
            guard let value, self[keyPath: keyPath] != value else { return }
            self[keyPath: keyPath] = value
            changed += 1
        }
        set(\.appearance, snapshot.appearance.flatMap(Appearance.init(rawValue:)))
        set(\.hoverPreviews, snapshot.hoverPreviews)
        set(\.showShortsOnHome, snapshot.showShortsOnHome)
        set(\.controlsTimeout, snapshot.controlsTimeout.flatMap { (1...60).contains($0) ? $0 : nil })
        set(\.maxHeight, snapshot.maxHeight.flatMap { height in Self.qualities.contains { $0.height == height } ? height : nil })
        set(\.codec, snapshot.codec.flatMap(VideoCodec.init(rawValue:)))
        set(\.buffer, snapshot.buffer.flatMap(BufferSize.init(rawValue:)))
        set(\.resumePlayback, snapshot.resumePlayback)
        set(\.autoplayNext, snapshot.autoplayNext)
        set(\.autoplayCountdown, snapshot.autoplayCountdown.flatMap { (0...60).contains($0) ? $0 : nil })
        set(\.subtitlesByDefault, snapshot.subtitlesByDefault)
        set(\.subtitleLanguage, snapshot.subtitleLanguage.flatMap { $0.count <= 12 && !$0.isEmpty ? $0 : nil })
        set(\.sponsorBlockEnabled, snapshot.sponsorBlockEnabled)
        set(\.sponsorBlockAutoSkip, snapshot.sponsorBlockAutoSkip)
        set(\.deArrowEnabled, snapshot.deArrowEnabled)
        set(\.deArrowTitles, snapshot.deArrowTitles)
        set(\.deArrowThumbnails, snapshot.deArrowThumbnails)
        set(\.showDislikes, snapshot.showDislikes)
        set(\.syncWatchHistory, snapshot.syncWatchHistory)
        set(\.spotlightEnabled, snapshot.spotlightEnabled)
        return changed
    }
}
