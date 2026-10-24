import Foundation
import Observation
#if os(Windows)
import WinSDK
#endif

/// Preferencias de la app en `UserDefaults` (los presenters de ajustes de SmartTube). Se pueden fijar al lanzar con
/// `-clave valor` (dominio de argumentos), p. ej. `-appearance dark` para las capturas.
@Observable
public final class AppSettings {
    public enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: "Sistema"
            case .light: "Claro"
            case .dark: "Oscuro"
            }
        }
    }

    /// Códec de video preferido (el resto queda de respaldo, en el orden de SmartTube).
    public enum VideoCodec: String, CaseIterable, Identifiable {
        case vp9, avc, av1
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .vp9: "VP9"
            case .avc: "H.264 (AVC)"
            case .av1: "AV1"
            }
        }
        /// Orden de códecs para SABR, con el preferido primero.
        public var order: [String] { [rawValue] + ["vp9", "avc", "av1"].filter { $0 != rawValue } }
    }

    /// Cuánto video se pide por delante de la posición (búfer de SmartTube: bajo, medio, alto).
    public enum BufferSize: Int, CaseIterable, Identifiable {
        case low = 15, medium = 30, high = 60
        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .low: "Bajo · 15 s"
            case .medium: "Medio · 30 s"
            case .high: "Alto · 60 s"
            }
        }
    }

    public static let qualities: [(height: Int, title: String)] = [
        (2160, "2160p (4K)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p"),
    ]

    private let defaults = UserDefaults.standard

    // Interfaz
    public var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); onAppearanceChange?(appearance) } }
    /// La interfaz aplica el tema (en WinUI, `RequestedTheme` de la ventana) al cambiar el ajuste.
    @ObservationIgnored public var onAppearanceChange: ((Appearance) -> Void)?
    public var hoverPreviews: Bool { didSet { save(hoverPreviews, "hoverPreviews") } }
    public var showShortsOnHome: Bool { didSet { save(showShortsOnHome, "showShortsOnHome") } }
    /// Segundos sin actividad antes de ocultar los controles del reproductor.
    public var controlsTimeout: Double { didSet { save(controlsTimeout, "controlsTimeout") } }

    // Reproductor
    public var maxHeight: Int { didSet { save(maxHeight, "maxHeight") } }
    public var codec: VideoCodec { didSet { save(codec.rawValue, "codec") } }
    public var buffer: BufferSize { didSet { save(buffer.rawValue, "buffer") } }
    public var resumePlayback: Bool { didSet { save(resumePlayback, "resumePlayback") } }
    /// Al terminar (sin nada en la cola), el siguiente de los sugeridos. La cola se reproduce siempre.
    public var autoplayNext: Bool { didSet { save(autoplayNext, "autoplayNext") } }
    /// Segundos de la cuenta atrás de «A continuación» antes de pasar al siguiente.
    public var autoplayCountdown: Double { didSet { save(autoplayCountdown, "autoplayCountdown") } }
    /// Panel lateral del reproductor: la última pestaña abierta.
    public var sidePanelTab: String { didSet { save(sidePanelTab, "sidePanelTab") } }

    // Subtítulos
    public var subtitlesByDefault: Bool { didSet { save(subtitlesByDefault, "subtitlesByDefault") } }
    public var subtitleLanguage: String { didSet { save(subtitleLanguage, "subtitleLanguage") } }

    // SponsorBlock
    public var sponsorBlockEnabled: Bool { didSet { save(sponsorBlockEnabled, "sponsorBlockEnabled") } }
    public var sponsorBlockAutoSkip: Bool { didSet { save(sponsorBlockAutoSkip, "sponsorBlockAutoSkip") } }

    // DeArrow (como `DeArrowData` de SmartTube: apagado por omisión) y Return YouTube Dislike
    public var deArrowEnabled: Bool { didSet { save(deArrowEnabled, "deArrowEnabled") } }
    public var deArrowTitles: Bool { didSet { save(deArrowTitles, "deArrowTitles") } }
    public var deArrowThumbnails: Bool { didSet { save(deArrowThumbnails, "deArrowThumbnails") } }
    public var showDislikes: Bool { didSet { save(showDislikes, "showDislikes") } }

    // Cuentas
    /// Reportar la posición vista al historial de YouTube cuando hay sesión.
    public var syncWatchHistory: Bool { didSet { save(syncWatchHistory, "syncWatchHistory") } }

    // Control remoto y sistema (fase 4)
    /// El enlace con la app de YouTube del teléfono (apagado por omisión, como `RemoteControlData` de SmartTube).
    public var remoteEnabled: Bool { didSet { save(remoteEnabled, "remoteEnabled") } }
    /// Cómo aparece la PC en el teléfono.
    public var remoteName: String { didSet { save(remoteName, "remoteName") } }

    // Actualizaciones
    /// Avisar de versiones nuevas (una consulta a la API de GitHub al abrir, como mucho una vez al día).
    public var checkForUpdates: Bool { didSet { save(checkForUpdates, "checkForUpdates") } }

    public init() {
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
        remoteName = d.string(forKey: "remoteName").flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultRemoteName
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

    public var qualityTitle: String {
        Self.qualities.first { $0.height == maxHeight }?.title ?? "\(maxHeight)p"
    }

    /// Nombre por omisión en el teléfono: «Glasstube en <nombre de la PC>» (como SmartTube: «<dispositivo> (<app>)»).
    public static var defaultRemoteName: String { "Glasstube en \(computerName ?? "PC")" }

    /// El nombre del equipo que se ve en la red (el de Configuración › Sistema › Información).
    public static var computerName: String? {
        #if os(Windows)
        var size: DWORD = 0
        _ = GetComputerNameExW(ComputerNamePhysicalDnsHostname, nil, &size)
        guard size > 0 else { return nil }
        var buffer = [WCHAR](repeating: 0, count: Int(size))
        guard GetComputerNameExW(ComputerNamePhysicalDnsHostname, &buffer, &size) else { return nil }
        let name = String(decoding: buffer.prefix(Int(size)), as: UTF16.self)
        return name.isEmpty ? nil : name
        #else
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? nil : name
        #endif
    }
}
