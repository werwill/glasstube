import Foundation
import Testing
import YTKit
import GlasstubeCore

/// Fase 5a: grupos de canales, suscripciones de esta PC, importar, bloqueos y filtros de búsqueda, sin red ni disco.
@MainActor
@Suite struct Phase5aTests {
    static let blender = GroupChannel(id: "UCSMOQeBJ2RAnuFungnQOxLg", title: "Blender")
    static let studio = GroupChannel(id: "UCz75RVbH8q2jdBJ4SnwuZZQ", title: "Blender Studio")

    static func video(_ id: String, channel: String?, author: String? = nil) -> MediaItem {
        var item = MediaItem(kind: .video, title: "Video \(id)", renderer: "prueba")
        item.videoId = id
        item.channelId = channel
        item.author = author
        return item
    }

    @Test func groupsAreCreatedRenamedMovedAndDeleted() throws {
        let store = ChannelGroupStore(fileURL: nil)
        let music = store.create(title: "  Música  ", channels: [Self.blender, Self.blender])
        let films = store.create(title: "Películas")
        let again = store.create(title: "música")
        #expect(store.groups.map(\.title) == ["Música", "Películas", "música 2"])
        #expect(music.channels == [Self.blender]) // sin repetidos

        store.rename(films.id, to: "Música")
        #expect(store.group(films.id)?.title == "Música 3") // no choca con «Música» ni con «música 2»
        store.rename(films.id, to: "   ")
        #expect(store.group(films.id)?.title == "Música 3") // un nombre vacío no cambia nada

        store.move(again.id, by: -1)
        #expect(store.groups.map(\.id) == [music.id, again.id, films.id])
        store.move(music.id, by: -1) // ya es el primero
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.groups.map(\.id) == [again.id, films.id, music.id])

        store.delete(again.id)
        #expect(store.groups.map(\.id) == [films.id, music.id])
    }

    @Test func channelsJoinAndLeaveGroups() throws {
        let store = ChannelGroupStore(fileURL: nil)
        let group = store.create(title: "Animación")
        store.add(GroupChannel(id: Self.studio.id), to: group.id)
        store.add(Self.blender, to: group.id)
        // Volver a agregarlo completa nombre y foto en lugar de duplicarlo.
        store.add(GroupChannel(id: Self.studio.id, title: "Blender Studio", avatarURL: "https://yt3.ggpht.com/a"), to: group.id)
        let channels = try #require(store.group(group.id)?.channels)
        #expect(channels.map(\.id) == [Self.studio.id, Self.blender.id])
        #expect(channels[0].avatarURL == "https://yt3.ggpht.com/a")
        #expect(store.groups(containing: Self.blender.id).map(\.id) == [group.id])

        store.remove(channelId: Self.blender.id, from: group.id)
        #expect(store.group(group.id)?.contains(Self.blender.id) == false)
    }

    @Test func localSubscriptions() {
        let store = ChannelGroupStore(fileURL: nil)
        store.subscribe(Self.blender)
        store.subscribe(Self.studio)
        store.subscribe(GroupChannel(id: Self.blender.id, avatarURL: "https://yt3.ggpht.com/b"))
        // La más reciente primero; repetir solo completa la foto.
        #expect(store.subscriptions.map(\.id) == [Self.studio.id, Self.blender.id])
        #expect(store.subscriptions[1].title == "Blender" && store.subscriptions[1].avatarURL == "https://yt3.ggpht.com/b")
        #expect(store.isSubscribed(Self.studio.id))
        store.unsubscribe(Self.studio.id)
        #expect(!store.isSubscribed(Self.studio.id))
    }

    @Test func feedTitlesFillImportedChannels() {
        let store = ChannelGroupStore(fileURL: nil)
        let group = store.create(title: "Importado", channels: [GroupChannel(id: Self.blender.id), GroupChannel(id: Self.studio.id, title: "Mi nombre")])
        store.subscribe(GroupChannel(id: Self.blender.id))
        store.update(titles: [Self.blender.id: "Blender", Self.studio.id: "Blender Studio"])
        #expect(store.group(group.id)?.channels.map(\.title) == ["Blender", "Mi nombre"]) // no pisa un nombre que ya había
        #expect(store.subscriptions.first?.title == "Blender")
    }

    @Test func importingMergesGroupsWithTheSameName() throws {
        let store = ChannelGroupStore(fileURL: nil)
        let existing = store.create(title: "animación abierta", channels: [Self.studio])
        let pocketTube = ChannelGroupImport(format: .pocketTube, groups: [
            ImportedGroup(title: "Animación abierta", channels: [ImportedChannel(channelId: Self.studio.id), ImportedChannel(channelId: Self.blender.id)]),
            ImportedGroup(title: "Software libre", channels: [ImportedChannel(channelId: Self.blender.id)]),
        ], skipped: 1)
        let summary = store.importGroups(pocketTube)
        #expect(summary.created == ["Software libre"])
        #expect(summary.updated == ["animación abierta"])
        #expect(summary.channelsAdded == 2)
        #expect(store.group(existing.id)?.channels.map(\.id) == [Self.studio.id, Self.blender.id])
        #expect(summary.message == "PocketTube: grupo «Software libre», «animación abierta» actualizado, 2 canales, 1 entrada omitida (no son canales de YouTube)")

        // Importar lo mismo otra vez no cambia nada.
        let again = store.importGroups(pocketTube)
        #expect(again.created.isEmpty && again.updated.isEmpty && store.groups.count == 2)
    }

    @Test func newPipeGoesToLocalSubscriptions() {
        let store = ChannelGroupStore(fileURL: nil)
        store.subscribe(Self.studio)
        let newPipe = ChannelGroupImport(format: .newPipe, groups: [ImportedGroup(title: "NewPipe", channels: [
            ImportedChannel(channelId: Self.blender.id, title: "Blender"), ImportedChannel(channelId: Self.studio.id, title: "Blender Studio"),
        ])], skipped: 0)
        let summary = store.importGroups(newPipe)
        #expect(store.groups.isEmpty)
        #expect(store.subscriptions.map(\.id) == [Self.studio.id, Self.blender.id])
        #expect(summary.subscriptionsAdded == 1)
        #expect(summary.message == "NewPipe: 1 suscripción nueva en esta PC")
    }

    @Test func storeSurvivesARestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glasstube-grupos-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChannelGroupStore(fileURL: url)
        let group = store.create(title: "Guardado", channels: [Self.blender])
        store.subscribe(Self.studio)
        // Se escribe poco después del último cambio.
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(200))
        let reopened = ChannelGroupStore(fileURL: url)
        #expect(reopened.groups == [group])
        #expect(reopened.subscriptions == [Self.studio])
    }

    @Test func blockedChannelsDisappearEverywhere() {
        let library = LocalLibrary(persistent: false)
        library.block(channelId: Self.blender.id, name: "Blender")
        var channelCard = MediaItem(kind: .channel, title: "Blender", renderer: "prueba")
        channelCard.channelId = Self.blender.id
        let items = [
            Self.video("a", channel: Self.blender.id, author: "Blender"),
            Self.video("b", channel: Self.studio.id, author: "Blender Studio"),
            // La búsqueda de TV no trae el id del canal: cuenta el nombre.
            Self.video("c", channel: nil, author: "Blender"),
            Self.video("d", channel: nil, author: "Otro canal"),
            channelCard,
        ]
        #expect(library.visible(items).map(\.id) == ["b", "d"])
        #expect(library.isBlocked(channelId: Self.blender.id))
        library.unblock(library.blockedChannels[0])
        #expect(library.visible(items).count == 5)
    }

    @Test func searchDestinationKeepsItsFilter() {
        let navigator = Navigator()
        navigator.go(.search("blender", .none))
        navigator.replace(.search("blender", SearchFilter(type: .video)))
        // Cambiar el filtro no deja otra entrada en «Atrás».
        #expect(navigator.backStack == [.section(.home)])
        #expect(navigator.current == .search("blender", SearchFilter(type: .video)))
    }

    @Test func channelFromACard() throws {
        var item = Self.video("v", channel: Self.blender.id, author: "Blender")
        item.authorThumbnails = [Thumbnail(url: "https://yt3.ggpht.com/88", width: 88, height: 88),
                                 Thumbnail(url: "https://yt3.ggpht.com/176", width: 176, height: 176)]
        let channel = try #require(GroupChannel(item: item))
        #expect(channel == GroupChannel(id: Self.blender.id, title: "Blender", avatarURL: "https://yt3.ggpht.com/88"))
        #expect(GroupChannel(item: Self.video("w", channel: nil)) == nil)
        #expect(GroupChannel(item: Self.video("w", channel: "@handle")) == nil)
    }
}
