import Foundation
import Testing
import YTKit
@testable import Glasstube

/// Fase 5b: el ZIP, el respaldo de Glasstube, el de SmartTube, los archivos para PocketTube y NewPipe, y restaurar
/// combinando con lo que hay. Sin red, sin disco de la app y sin los ajustes de esta Mac (otro dominio de UserDefaults).
@MainActor
@Suite struct BackupTests {
    static let blender = GroupChannel(id: "UCSMOQeBJ2RAnuFungnQOxLg", title: "Blender")
    static let studio = GroupChannel(id: "UCz75RVbH8q2jdBJ4SnwuZZQ", title: "Blender Studio")

    static func video(_ id: String, _ title: String = "Video", channel: String? = nil) -> MediaItem {
        var item = MediaItem(kind: .video, title: title, renderer: "prueba")
        item.videoId = id
        item.channelId = channel
        return item
    }

    /// Almacenes en memoria y ajustes en un dominio propio, que se borra al terminar.
    @MainActor struct Stores {
        let stores: BackupStores
        let suite: String

        init() {
            suite = "glasstube-pruebas-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            stores = BackupStores(library: LocalLibrary(persistent: false), groups: ChannelGroupStore(fileURL: nil),
                                  queue: PlayQueue(), settings: AppSettings(defaults: defaults))
        }

        func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }
    }

    // MARK: - ZIP

    @Test func zipRoundTripWithDeflateAndStoredEntries() throws {
        let big = Data(String(repeating: "Glasstube respaldo ", count: 400).utf8)
        let small = Data("{}".utf8)
        let utf8 = Data("Música · Animación".utf8)
        let zip = ZipArchive.make([.init(path: "a.json", data: big), .init(path: "b.json", data: small),
                                   .init(path: "carpeta/ñ.txt", data: utf8), .init(path: "vacío", data: Data())])
        #expect(zip.count < big.count) // lo grande va comprimido
        let entries = try ZipArchive.read(zip)
        #expect(entries.map(\.path) == ["a.json", "b.json", "carpeta/ñ.txt", "vacío"])
        #expect(entries.map(\.data) == [big, small, utf8, Data()])
    }

    @Test func zipReadsWhatUnzipWrites() throws {
        // `/usr/bin/zip` (DEFLATE, cabeceras extra de Unix) y `ditto -c -k`: lo que sale de Finder al comprimir.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gt-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dentro"), withIntermediateDirectories: true)
        let text = Data(String(repeating: "línea de prueba\n", count: 200).utf8)
        try text.write(to: folder.appendingPathComponent("dentro/texto.txt"))
        for tool in [["/usr/bin/zip", "-qr", "z.zip", "dentro"], ["/usr/bin/ditto", "-c", "-k", "--keepParent", "dentro", "d.zip"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool[0])
            process.arguments = Array(tool.dropFirst())
            process.currentDirectoryURL = folder
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        for name in ["z.zip", "d.zip"] {
            let entries = try ZipArchive.read(try Data(contentsOf: folder.appendingPathComponent(name)))
            #expect(entries.first { $0.path == "dentro/texto.txt" }?.data == text, "\(name)")
        }
    }

    @Test func zipRejectsWhatIsNotAZipOrIsDamaged() throws {
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive.read(Data("hola".utf8)) }
        var zip = ZipArchive.make([.init(path: "a.txt", data: Data(String(repeating: "abc", count: 100).utf8))])
        zip[40] ^= 0xFF // un byte de los datos comprimidos
        #expect(throws: (any Error).self) { try ZipArchive.read(zip) }
    }

    // MARK: - Respaldo de Glasstube

    @Test func backupRoundTripKeepsEverythingButTokens() throws {
        let fixture = Stores()
        defer { fixture.tearDown() }
        let stores = fixture.stores
        let group = stores.groups.create(title: "Animación", channels: [Self.studio, Self.blender])
        stores.groups.subscribe(Self.blender)
        stores.library.block(channelId: "UCpruebaBloqueado0000001", name: "Canal de prueba")
        var watched = Self.video("aqz-KE-bpKQ", "Big Buck Bunny", channel: Self.blender.id)
        watched.feedbackToken = "TOKEN-DE-LA-CUENTA"
        watched.menuPanel = try JSONDecoder().decode(MenuPanel.self, from: Data(#"{"panelId":"panel","params":"PARAMS-DE-LA-CUENTA"}"#.utf8))
        stores.library.recordPlayback(of: watched, position: 120, duration: 596)
        stores.library.toggleWatchLater(Self.video("eRsGyueVLvQ", "Sintel"))
        stores.library.hide(Self.video("WhWc3b3KhnY"))
        stores.queue.append(Self.video("eRsGyueVLvQ", "Sintel"))
        stores.settings.maxHeight = 1440
        stores.settings.deArrowEnabled = true

        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let zip = try BackupArchive.make(stores.contents(), appVersion: "0.6.0", date: date)
        let text = try ZipArchive.read(zip).map { String(decoding: $0.data, as: UTF8.self) }.joined()
        #expect(!text.contains("TOKEN-DE-LA-CUENTA") && !text.contains("PARAMS-DE-LA-CUENTA"))
        #expect(try ZipArchive.read(zip).map(\.path) == ["manifest.json", "groups.json", "library.json", "queue.json", "settings.json"])

        let file = try BackupArchive.read(zip)
        #expect(file.source == .glasstube(app: "0.6.0", created: date))
        #expect(file.contents.groups == [group])
        #expect(file.contents.subscriptions == [Self.blender])
        #expect(file.contents.blockedChannels.map(\.id) == ["UCpruebaBloqueado0000001"])
        #expect(file.contents.history.first?.position == 120)
        #expect(file.contents.history.first?.item.feedbackToken == nil)
        #expect(file.contents.watchLater.map(\.item.videoId) == ["eRsGyueVLvQ"])
        #expect(file.contents.hiddenVideos == ["WhWc3b3KhnY"])
        #expect(file.contents.queue.map(\.videoId) == ["eRsGyueVLvQ"])
        #expect(file.contents.settings?.maxHeight == 1440 && file.contents.settings?.deArrowEnabled == true)
        #expect(file.contents.sections == BackupSection.allCases)
    }

    @Test func backupNeverCarriesAccountOrPerMacSettings() throws {
        let fixture = Stores()
        defer { fixture.tearDown() }
        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.stores.settings.snapshot)) as? [String: Any]
        let keys = Set(settings?.keys.map { $0 } ?? [])
        // La vinculación del teléfono, su nombre, el aviso de versiones y iCloud Drive son de cada Mac.
        for key in ["remoteEnabled", "remoteName", "remoteIdentity", "checkForUpdates", "iCloudBackup", "updatesLastCheck"] {
            #expect(!keys.contains(key), "\(key)")
        }
        #expect(keys.count == fixture.stores.settings.snapshot.count)
    }

    @Test func unknownAndNewerBackupsAreRejected() throws {
        #expect(throws: BackupArchive.Failure.unknown) { try BackupArchive.read(Data("no es un zip".utf8)) }
        let other = ZipArchive.make([.init(path: "foto.jpg", data: Data([0xFF, 0xD8]))])
        #expect(throws: BackupArchive.Failure.unknown) { try BackupArchive.read(other) }
        let newer = ZipArchive.make([.init(path: "manifest.json", data: Data(#"{"format":"mx.glasstube.respaldo","version":9}"#.utf8))])
        #expect(throws: BackupArchive.Failure.newerVersion(9)) { try BackupArchive.read(newer) }
    }

    @Test func backupInsideAFolderStillReads() throws {
        // Abierto en Finder y vuelto a comprimir: todo queda dentro de una carpeta (y con __MACOSX).
        let fixture = Stores()
        defer { fixture.tearDown() }
        fixture.stores.groups.subscribe(Self.studio)
        let original = try ZipArchive.read(try BackupArchive.make(fixture.stores.contents(), appVersion: nil))
        let rezipped = ZipArchive.make(original.map { .init(path: "Glasstube-respaldo/\($0.path)", data: $0.data) }
                                       + [.init(path: "__MACOSX/Glasstube-respaldo/._manifest.json", data: Data([0, 5, 22, 7]))])
        #expect(try BackupArchive.read(rezipped).contents.subscriptions == [Self.studio])
    }

    // MARK: - Restaurar

    @Test func restoringMergesWithoutDeletingAnything() throws {
        let fixture = Stores()
        defer { fixture.tearDown() }
        let stores = fixture.stores
        // En esta Mac: un grupo «Animación» con Blender, una suscripción, un bloqueo y un video visto hace poco.
        stores.groups.create(title: "Animación", channels: [GroupChannel(id: Self.blender.id)])
        stores.groups.subscribe(Self.studio)
        stores.library.block(channelId: "UCpruebaBloqueado0000001", name: "Uno")
        stores.library.recordPlayback(of: Self.video("aqz-KE-bpKQ"), position: 300, duration: 596)
        stores.queue.append(Self.video("WhWc3b3KhnY"))

        let old = Date(timeIntervalSinceNow: -3600)
        var backup = BackupContents()
        backup.groups = [ChannelGroup(id: "otro-id", title: "animación", channels: [Self.blender, Self.studio]),
                         ChannelGroup(id: "g2", title: "Música", channels: [Self.studio])]
        backup.subscriptions = [Self.studio, Self.blender]
        backup.blockedChannels = [BlockedChannel(id: "UCpruebaBloqueado0000001", name: "Uno"), BlockedChannel(id: "UCpruebaBloqueado0000002", name: "Dos")]
        backup.history = [SavedVideo(item: Self.video("aqz-KE-bpKQ"), position: 10, duration: 596, updatedAt: old),
                          SavedVideo(item: Self.video("eRsGyueVLvQ"), position: 50, duration: 888, updatedAt: old)]
        backup.watchLater = [SavedVideo(item: Self.video("WhWc3b3KhnY"), position: 0, duration: nil, updatedAt: old)]
        backup.hiddenVideos = ["xxxxxxxxxxx"]
        backup.queue = [Self.video("WhWc3b3KhnY"), Self.video("eRsGyueVLvQ")]
        var settings = SettingsSnapshot()
        settings.codec = "av1"
        settings.maxHeight = 999 // no es una calidad válida: se ignora
        backup.settings = settings

        let summary = stores.restore(backup, sections: Set(BackupSection.allCases))
        #expect(stores.groups.groups.map(\.title) == ["Animación", "Música"])
        #expect(stores.groups.groups[0].channels.map(\.id) == [Self.blender.id, Self.studio.id])
        #expect(stores.groups.groups[0].channels[0].title == "Blender") // completó el nombre que faltaba
        #expect(stores.groups.subscriptions.map(\.id) == [Self.studio.id, Self.blender.id])
        #expect(stores.library.blockedChannels.map(\.name) == ["Uno", "Dos"])
        // El video visto aquí hace poco conserva su posición; el del respaldo entra después.
        #expect(stores.library.history.map(\.item.videoId) == ["aqz-KE-bpKQ", "eRsGyueVLvQ"])
        #expect(stores.library.history[0].position == 300)
        #expect(stores.library.watchLater.count == 1 && stores.library.hiddenVideos == ["xxxxxxxxxxx"])
        #expect(stores.queue.items.map(\.videoId) == ["WhWc3b3KhnY", "eRsGyueVLvQ"])
        #expect(stores.settings.codec == .av1 && stores.settings.maxHeight == 1080)
        #expect(summary == BackupRestoreSummary(groupsCreated: 1, groupsUpdated: 1, subscriptions: 1, blocked: 1, history: 3,
                                                queue: 1, settings: 1))
        #expect(summary.message.hasPrefix("Se restauró: 1 grupo nuevo, 1 grupo con canales nuevos"))

        // Otra vez lo mismo: nada nuevo.
        #expect(stores.restore(backup, sections: Set(BackupSection.allCases)).message.hasPrefix("No había nada nuevo"))
    }

    @Test func onlyTheChosenSectionsAreRestored() {
        let fixture = Stores()
        defer { fixture.tearDown() }
        var backup = BackupContents()
        backup.groups = [ChannelGroup(id: "g", title: "Música", channels: [Self.studio])]
        backup.blockedChannels = [BlockedChannel(id: "UCpruebaBloqueado0000002", name: "Dos")]
        var settings = SettingsSnapshot()
        settings.appearance = "dark"
        backup.settings = settings
        fixture.stores.restore(backup, sections: [.blocked])
        #expect(fixture.stores.groups.groups.isEmpty)
        #expect(fixture.stores.library.blockedChannels.count == 1)
        #expect(fixture.stores.settings.appearance == .system)
    }

    // MARK: - SmartTube

    @Test func smartTubeBackupBringsWhatHasAnEquivalent() throws {
        let url = try #require(Bundle.module.url(forResource: "smarttube-respaldo", withExtension: "zip", subdirectory: "Fixtures"))
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let file = try BackupArchive.read(try Data(contentsOf: url), date: now)
        #expect(file.source == .smartTube)
        let contents = file.contents
        // Historial: del más nuevo al más viejo, sin repetir (vale la última posición de Sintel) y debajo de lo de hoy.
        #expect(contents.history.map(\.item.videoId) == ["eRsGyueVLvQ", "WhWc3b3KhnY", "aqz-KE-bpKQ"])
        #expect(contents.history.map(\.position) == [300, 200, 30])
        #expect(contents.history[0].duration == 888 && contents.history[2].duration == nil)
        #expect(contents.history[0].item.title == "Sintel" && contents.history[0].item.author == "Blender")
        #expect(contents.history[0].item.channelId == Self.blender.id)
        #expect(contents.history[2].item.title == "aqz-KE-bpKQ") // el formato viejo solo traía el id
        #expect(contents.history.allSatisfy { $0.updatedAt < now })
        // Grupos: el «1000» son las suscripciones; el «1001» (avisos) no; el del XML viejo, sí.
        #expect(contents.subscriptions.map(\.id) == [Self.studio.id, Self.blender.id])
        #expect(contents.subscriptions[0].title == "Blender Studio")
        #expect(contents.groups.map(\.title) == ["Música & CC", "Animación libre"] || contents.groups.map(\.title) == ["Animación libre", "Música & CC"])
        #expect(contents.groups.first { $0.title == "Animación libre" }?.channels.map(\.id) == [Self.studio.id])
        #expect(contents.blockedChannels.map(\.id) == ["UCpruebaBloqueado0000001", "UCpruebaBloqueadoViejo01"])
        #expect(contents.blockedChannels.map(\.name) == ["Canal de prueba", "Canal viejo"])
        #expect(contents.settings == nil && contents.queue.isEmpty)
        #expect(file.notes.contains { $0.contains("3 entradas") })
        #expect(contents.sections == [.groups, .subscriptions, .blocked, .history])
    }

    @Test func smartTubeVideoSpecs() {
        // 23 campos; con «•» el canal es lo primero del subtítulo.
        let fields = ["-1", "null", "Spring", "WhWc3b3KhnY", "null", "null", "UCz75RVbH8q2jdBJ4SnwuZZQ", "null", "null", "null",
                      "null", "-1", "null", "-1", "Blender Studio • 12 M de vistas", "null", "0.0", "null", "null", "null", "true",
                      "null", "null"]
        let item = SmartTubeBackup.video(fields.joined(separator: "&vi;"))
        #expect(item?.videoId == "WhWc3b3KhnY" && item?.author == "Blender Studio" && item?.isLive == true)
        #expect(SmartTubeBackup.video("WhWc3b3KhnY")?.title == "WhWc3b3KhnY")
        #expect(SmartTubeBackup.video("null") == nil && SmartTubeBackup.video("") == nil)
        #expect(SmartTubeBackup.split(" ", "%AR%").isEmpty) // SmartTube guarda una lista vacía como un espacio
    }

    // MARK: - Otras apps

    @Test func pocketTubeExportReadsBackInOrder() throws {
        let groups = [ChannelGroup(id: "1", title: "Zeta \"comillas\"", channels: [Self.studio, GroupChannel(id: "no-es-un-canal")]),
                      ChannelGroup(id: "2", title: "Alfa", channels: [Self.blender])]
        let data = ExternalExport.pocketTube(groups: groups)
        let imported = try #require(ChannelGroupImport.parse(data))
        #expect(imported.format == .pocketTube)
        #expect(imported.groups.map(\.title) == ["Zeta \"comillas\"", "Alfa"]) // en el orden de Glasstube, no el alfabético
        #expect(imported.groups.map { $0.channels.map(\.channelId) } == [[Self.studio.id], [Self.blender.id]])
    }

    @Test func newPipeExportReadsBack() throws {
        let data = ExternalExport.newPipe(channels: [Self.blender, GroupChannel(id: Self.studio.id), GroupChannel(id: "x")])
        let imported = try #require(ChannelGroupImport.parse(data))
        #expect(imported.format == .newPipe && imported.skipped == 0)
        #expect(imported.groups.first?.channels == [ImportedChannel(channelId: Self.blender.id, title: "Blender"),
                                                     ImportedChannel(channelId: Self.studio.id, title: Self.studio.id)])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["app_version"] != nil && root["app_version_int"] != nil)
    }

    @Test func fileNamesAndDays() {
        var parts = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 6, hour: 23)
        parts.timeZone = .current
        #expect(BackupArchive.fileName(for: parts.date!) == "Glasstube-respaldo-2026-10-06.zip")
    }
}
