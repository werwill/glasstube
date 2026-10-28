import AppKit
import Foundation
import Observation
import Sparkle

/// Actualizaciones dentro de la app con Sparkle 2 (fase 5b; `appupdatechecker2` de SmartTube). Sparkle lee el appcast
/// (`SUFeedURL`), baja el DMG de la versión de GitHub Releases, comprueba su firma EdDSA con `SUPublicEDKey` y la firma
/// de código (el mismo certificado que la app instalada), reemplaza la app y la vuelve a abrir. Las ventanas son las de
/// Sparkle (en español).
///
/// Solo existe si `Scripts/package-app.sh` puso `SUFeedURL` y `SUPublicEDKey` en el `Info.plist` (la clave pública sale
/// de `Packaging/sparkle-clave-publica.txt`, que crea quien publica con `generate_keys`). Sin ellos (una compilación sin
/// clave, `swift run`), la app sigue con el aviso de GitHub de `UpdateChecker`.
@Observable
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let feedOverride: String?
    @ObservationIgnored private let legacySettings: AppSettings

    /// Sparkle puede buscar ahora (no hay otra búsqueda ni una instalación en curso).
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    private(set) var automaticallyChecks = true
    private(set) var automaticallyDownloads = false
    /// La versión que encontró la última búsqueda, mientras no se instala.
    private(set) var foundVersion: String?

    /// `SUFeedURL` y `SUPublicEDKey` en el `Info.plist`.
    static func isConfigured(_ bundle: Bundle = .main) -> Bool {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    var feedURL: String? { feedOverride ?? Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }

    init(settings: AppSettings) {
        legacySettings = settings
        // `-GTActualizacionesFeed url`: otro appcast (pruebas con un servidor local).
        feedOverride = UserDefaults.standard.string(forKey: "GTActualizacionesFeed")
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    private var updater: SPUUpdater { controller.updater }

    /// Arranca Sparkle (busca solo si toca: una vez al día con la búsqueda automática encendida).
    func start() {
        // Quien había apagado el aviso de versiones de GitHub (antes de Sparkle) tampoco quiere búsquedas automáticas.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil, !legacySettings.checkForUpdates {
            updater.automaticallyChecksForUpdates = false
        }
        controller.startUpdater()
        observations = [
            // Sparkle cambia estas propiedades en el hilo principal (sus métodos solo se usan desde ahí).
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                MainActor.assumeIsolated { self?.lastCheck = value }
            },
        ]
        refresh()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Búsqueda sin ventanas salvo que haya una versión (automatización).
    func checkInBackground() {
        updater.checkForUpdatesInBackground()
    }

    func setAutomaticallyChecks(_ value: Bool) {
        updater.automaticallyChecksForUpdates = value
        legacySettings.checkForUpdates = value
        refresh()
    }

    func setAutomaticallyDownloads(_ value: Bool) {
        updater.automaticallyDownloadsUpdates = value
        refresh()
    }

    private func refresh() {
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "GTActualizacionesFeed")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            foundVersion = version
            if Automation.shared.logsUpdates { NSLog("Glasstube actualizaciones: versión \(version) (\(item.versionString)) en \(item.fileURL?.absoluteString ?? "?")") }
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let message = (error as NSError).localizedDescription
        MainActor.assumeIsolated {
            foundVersion = nil
            if Automation.shared.logsUpdates { NSLog("Glasstube actualizaciones: sin versión nueva (\(message))") }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let message = (error as NSError).localizedDescription
        MainActor.assumeIsolated {
            if Automation.shared.logsUpdates { NSLog("Glasstube actualizaciones: error: \(message)") }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            if Automation.shared.logsUpdates { NSLog("Glasstube actualizaciones: se instala \(version)") }
        }
    }
}
