import AppKit
import Foundation
import Observation

/// Preferencias de la app en `UserDefaults` (los presenters de ajustes de SmartTube). Se pueden fijar al lanzar con
/// `-clave valor` (dominio de argumentos), p. ej. `-appearance dark` para las capturas.
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Sistema"
            case .light: "Claro"
            case .dark: "Oscuro"
            }
        }
    }

    /// Códec de video preferido (el resto queda de respaldo, en el orden de SmartTube).
    enum VideoCodec: String, CaseIterable, Identifiable {
        case vp9, avc, av1
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vp9: "VP9"
            case .avc: "H.264 (AVC)"
            case .av1: "AV1"
            }
        }
        /// Orden de códecs para SABR, con el preferido primero.
        var order: [String] { [rawValue] + ["vp9", "avc", "av1"].filter { $0 != rawValue } }
    }

    /// Cuánto video se pide por delante de la posición (búfer de SmartTube: bajo, medio, alto).
    enum BufferSize: Int, CaseIterable, Identifiable {
        case low = 15, medium = 30, high = 60
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .low: "Bajo · 15 s"
            case .medium: "Medio · 30 s"
            case .high: "Alto · 60 s"
            }
        }
    }

    static let qualities: [(height: Int, title: String)] = [
        (2160, "2160p (4K)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p"),
    ]

    private let defaults = UserDefaults.standard

    // Interfaz
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    var hoverPreviews: Bool { didSet { save(hoverPreviews, "hoverPreviews") } }
    var showShortsOnHome: Bool { didSet { save(showShortsOnHome, "showShortsOnHome") } }
    /// Segundos sin actividad antes de ocultar los controles del reproductor.
    var controlsTimeout: Double { didSet { save(controlsTimeout, "controlsTimeout") } }

    // Reproductor
    var maxHeight: Int { didSet { save(maxHeight, "maxHeight") } }
    var codec: VideoCodec { didSet { save(codec.rawValue, "codec") } }
    var buffer: BufferSize { didSet { save(buffer.rawValue, "buffer") } }
    var resumePlayback: Bool { didSet { save(resumePlayback, "resumePlayback") } }
    /// Al terminar (sin nada en la cola), el siguiente de los sugeridos. La cola se reproduce siempre.
    var autoplayNext: Bool { didSet { save(autoplayNext, "autoplayNext") } }
    /// Segundos de la cuenta atrás de «A continuación» antes de pasar al siguiente.
    var autoplayCountdown: Double { didSet { save(autoplayCountdown, "autoplayCountdown") } }
    /// Panel lateral del reproductor: la última pestaña abierta.
    var sidePanelTab: String { didSet { save(sidePanelTab, "sidePanelTab") } }

    // Subtítulos
    var subtitlesByDefault: Bool { didSet { save(subtitlesByDefault, "subtitlesByDefault") } }
    var subtitleLanguage: String { didSet { save(subtitleLanguage, "subtitleLanguage") } }

    // SponsorBlock
    var sponsorBlockEnabled: Bool { didSet { save(sponsorBlockEnabled, "sponsorBlockEnabled") } }
    var sponsorBlockAutoSkip: Bool { didSet { save(sponsorBlockAutoSkip, "sponsorBlockAutoSkip") } }

    // DeArrow (como `DeArrowData` de SmartTube: apagado por omisión) y Return YouTube Dislike
    var deArrowEnabled: Bool { didSet { save(deArrowEnabled, "deArrowEnabled") } }
    var deArrowTitles: Bool { didSet { save(deArrowTitles, "deArrowTitles") } }
    var deArrowThumbnails: Bool { didSet { save(deArrowThumbnails, "deArrowThumbnails") } }
    var showDislikes: Bool { didSet { save(showDislikes, "showDislikes") } }

    // Cuentas
    /// Reportar la posición vista al historial de YouTube cuando hay sesión.
    var syncWatchHistory: Bool { didSet { save(syncWatchHistory, "syncWatchHistory") } }

    // Control remoto y sistema (fase 4)
    /// El enlace con la app de YouTube del teléfono (apagado por omisión, como `RemoteControlData` de SmartTube).
    var remoteEnabled: Bool { didSet { save(remoteEnabled, "remoteEnabled") } }
    /// Cómo aparece la Mac en el teléfono.
    var remoteName: String { didSet { save(remoteName, "remoteName") } }
    /// Agregar a Spotlight los videos vistos y sus canales.
    var spotlightEnabled: Bool { didSet { save(spotlightEnabled, "spotlightEnabled") } }

    // Actualizaciones
    /// Avisar de versiones nuevas (una consulta a la API de GitHub al abrir, como mucho una vez al día).
    var checkForUpdates: Bool { didSet { save(checkForUpdates, "checkForUpdates") } }

    init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        hoverPreviews = Self.flag(d, "hoverPreviews", true)
        showShortsOnHome = Self.flag(d, "showShortsOnHome", false)
        controlsTimeout = Self.number(d, "controlsTimeout", 3)
        maxHeight = Int(Self.number(d, "maxHeight", 1080))
        codec = VideoCodec(rawValue: d.string(forKey: "codec") ?? "") ?? .vp9
        buffer = BufferSize(rawValue: d.integer(forKey: "buffer")) ?? .medium
        resumePlayback = Self.flag(d, "resumePlayback", true)
        // SmartTube reproduce todo por omisión (`PLAYBACK_MODE_ALL`).
        autoplayNext = Self.flag(d, "autoplayNext", true)
        autoplayCountdown = Self.number(d, "autoplayCountdown", 8)
        sidePanelTab = d.string(forKey: "sidePanelTab") ?? "description"
        subtitlesByDefault = Self.flag(d, "subtitlesByDefault", false)
        subtitleLanguage = d.string(forKey: "subtitleLanguage") ?? (Locale.current.language.languageCode?.identifier ?? "es")
        sponsorBlockEnabled = Self.flag(d, "sponsorBlockEnabled", true)
        sponsorBlockAutoSkip = Self.flag(d, "sponsorBlockAutoSkip", false)
        deArrowEnabled = Self.flag(d, "deArrowEnabled", false)
        deArrowTitles = Self.flag(d, "deArrowTitles", true)
        deArrowThumbnails = Self.flag(d, "deArrowThumbnails", true)
        showDislikes = Self.flag(d, "showDislikes", true)
        syncWatchHistory = Self.flag(d, "syncWatchHistory", true)
        remoteEnabled = Self.flag(d, "remoteEnabled", false)
        remoteName = d.string(forKey: "remoteName").flatMap { $0.isEmpty ? nil : $0 } ?? RemoteControl.defaultName
        spotlightEnabled = Self.flag(d, "spotlightEnabled", true)
        checkForUpdates = Self.flag(d, "checkForUpdates", true)
    }

    /// Booleano de `UserDefaults` con valor por omisión. `bool(forKey:)` entiende también "YES"/"NO" como texto, que es
    /// como llegan las opciones de arranque (`-deArrowEnabled YES`); `object(forKey:) as? Bool` no.
    private static func flag(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// Número de `UserDefaults` con valor por omisión; acepta también texto ("5"), como llegan las opciones de arranque.
    private static func number(_ defaults: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    var qualityTitle: String {
        Self.qualities.first { $0.height == maxHeight }?.title ?? "\(maxHeight)p"
    }

    /// Fija la apariencia de toda la app (ventanas, menús, ajustes).
    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
