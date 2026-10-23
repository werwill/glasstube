import Foundation
import Testing
@testable import YTKit

// Fase 5a: feeds RSS, filtros de búsqueda, Shorts e importar grupos de canales.

@Suite struct RSSFeedTests {
    @Test func parsesChannelFeed() throws {
        let feed = try RSSFeedParser.parse(try Fixture.data("descubrir/rss-blender.xml"), channelId: "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(feed.title == "Blender")
        #expect(feed.channelId == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(feed.items.count == 3)
        let video = try #require(feed.items.first { $0.videoId == "dVrELpmfcEQ" })
        #expect(video.title == "Blender Education Community Meeting — BCON26")
        #expect(video.channelId == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(video.author == "Blender")
        #expect(video.viewCount == 4280)
        #expect(!video.isShort)
        #expect(video.thumbnails.first?.url == "https://i1.ytimg.com/vi/dVrELpmfcEQ/hqdefault.jpg")
        #expect(video.publishedAt == ISO8601DateFormatter().date(from: "2026-10-23T09:37:25Z"))
        #expect(video.descriptionSnippet?.hasPrefix("The recording") == true)
        // Los Shorts se reconocen por el enlace /shorts/.
        #expect(feed.items.filter(\.isShort).map(\.videoId) == ["YsKxkP_kGbE", "EycY6jDFK74"])
    }

    @Test func channelIdComesFromTheFeedWhenNotGiven() throws {
        let feed = try RSSFeedParser.parse(try Fixture.data("descubrir/rss-blender.xml"))
        #expect(feed.channelId == "UCSMOQeBJ2RAnuFungnQOxLg")
    }

    @Test func rejectsWhatIsNotAFeed() {
        #expect(throws: (any Error).self) { try RSSFeedParser.parse(Data("<html><body>404</body></html>".utf8)) }
    }

    /// Un GET falso que cuenta las peticiones y responde por canal.
    final class FakeFeeds: @unchecked Sendable {
        let lock = NSLock()
        var requests: [String] = []
        var failing: Set<String> = []
        let feed: Data

        init() throws { feed = try Fixture.data("descubrir/rss-blender.xml") }

        func fetch(_ url: URL) async throws -> (Data, Int) {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            let fails = lock.withLock { requests.append(id); return failing.contains(id) }
            if fails { return (Data(), 500) }
            // Cada canal da el mismo feed con su id, para ver la mezcla.
            let text = String(decoding: feed, as: UTF8.self)
                .replacingOccurrences(of: "<yt:videoId>", with: "<yt:videoId>\(id.suffix(3))-")
            return (Data(text.utf8), 200)
        }

        var count: Int { lock.withLock { requests.count } }
    }

    @Test func mergesChannelsSortedByDateAndCaches() async throws {
        let fake = try FakeFeeds()
        let service = RSSFeedService(usesDisk: false) { try await fake.fetch($0) }
        let ids = (1...12).map { String(format: "UCcanaldeprueba%09d", $0) }
        let first = await service.feed(channelIds: ids + [ids[0]], locale: CatalogLocale(language: "es-419", region: "MX"))
        #expect(fake.count == 12) // sin repetir el canal duplicado
        #expect(first.items.count == 36)
        #expect(first.failed.isEmpty && first.cached == 0)
        let dates = first.items.compactMap(\.publishedAt)
        #expect(dates == dates.sorted(by: >))
        #expect(first.items.allSatisfy { $0.publishedText?.hasPrefix("hace") == true || $0.publishedText?.contains("hace") == true })
        #expect(first.items.first { $0.viewCount == 4280 }?.viewCountText == "4.3 K vistas")
        #expect(first.channelTitles[ids[3]] == "Blender")

        // Dentro del TTL, de la caché; con `refresh`, otra vez a la red.
        let second = await service.feed(channelIds: ids)
        #expect(fake.count == 12 && second.cached == 12 && second.items.count == 36)
        _ = await service.feed(channelIds: Array(ids.prefix(2)), refresh: true)
        #expect(fake.count == 14)
    }

    @Test func failingChannelsFallBackToTheirOldCopy() async throws {
        let fake = try FakeFeeds()
        let service = RSSFeedService(ttl: 0, usesDisk: false) { try await fake.fetch($0) }
        let ids = ["UCcanaldeprueba000000001", "UCcanaldeprueba000000002"]
        _ = await service.feed(channelIds: ids)
        fake.lock.withLock { fake.failing = [ids[1], "UCcanaldeprueba000000003"] }
        let result = await service.feed(channelIds: ids + ["UCcanaldeprueba000000003"])
        // El que falla con copia sale de la caché; el nuevo que falla (con un reintento) queda en `failed`.
        #expect(result.cached == 1)
        #expect(result.failed == ["UCcanaldeprueba000000003"])
        #expect(result.items.count == 6)
        #expect(fake.count == 2 + 1 + 2 + 2)
    }

    @Test func viewsAreWrittenLikeYouTube() {
        #expect(RSSFeedService.viewsText(1, language: "es-419") == "1 vista")
        #expect(RSSFeedService.viewsText(950, language: "es-419") == "950 vistas")
        #expect(RSSFeedService.viewsText(1_250_000, language: "es-419").hasSuffix("M de vistas"))
        #expect(RSSFeedService.viewsText(2_300, language: "en") == "2.3K views")
    }
}

@Suite struct SearchFilterTests {
    /// Los `params` que da la propia interfaz WEB en su diálogo «Filtros de búsqueda» (23-oct-2026).
    @Test func matchesYouTubesOwnParams() {
        #expect(SearchFilter.none.params == nil)
        #expect(SearchFilter(type: .video).params == "EgIQAQ==")
        #expect(SearchFilter(type: .shorts).params == "EgIQCQ==")
        #expect(SearchFilter(type: .channel).params == "EgIQAg==")
        #expect(SearchFilter(type: .playlist).params == "EgIQAw==")
        #expect(SearchFilter(type: .movie).params == "EgIQBA==")
        #expect(SearchFilter(duration: .underThree).params == "EgIYBA==")
        #expect(SearchFilter(duration: .threeToTwenty).params == "EgIYBQ==")
        #expect(SearchFilter(duration: .overTwenty).params == "EgIYAg==")
        #expect(SearchFilter(uploadDate: .today).params == "EgIIAg==")
        #expect(SearchFilter(uploadDate: .week).params == "EgIIAw==")
        #expect(SearchFilter(uploadDate: .month).params == "EgIIBA==")
        #expect(SearchFilter(uploadDate: .year).params == "EgIIBQ==")
        #expect(SearchFilter(priority: .popularity).params == "CAM=")
        #expect(SearchFilter(features: [.live]).params == "EgJAAQ==")
        #expect(SearchFilter(features: [.uhd]).params == "EgJwAQ==")
        #expect(SearchFilter(features: [.hd]).params == "EgIgAQ==")
        #expect(SearchFilter(features: [.subtitles]).params == "EgIoAQ==")
        #expect(SearchFilter(features: [.creativeCommons]).params == "EgIwAQ==")
        #expect(SearchFilter(features: [.hdr]).params == "EgPIAQE=")
    }

    @Test func combinesFilters() {
        // Comprobados contra YouTube: esta semana + videos + de 3 a 20 minutos, y lo mismo por popularidad.
        let week = SearchFilter(uploadDate: .week, type: .video, duration: .threeToTwenty)
        #expect(week.params == "EgYIAxABGAU=")
        var popular = week
        popular.priority = .popularity
        #expect(popular.params == "CAMSBggDEAEYBQ==")
        #expect(popular.activeCount == 4)
        #expect(SearchFilter(features: [.creativeCommons, .hd]).params == "EgQgATAB")
    }

    @Test func readsParamsBack() {
        let filter = SearchFilter(priority: .popularity, uploadDate: .month, type: .shorts, duration: .underThree,
                                  features: [.creativeCommons, .uhd])
        #expect(SearchFilter(params: filter.params!) == filter)
        #expect(SearchFilter(params: "EgIQAQ%3D%3D") == SearchFilter(type: .video))
        #expect(SearchFilter(params: "esto no es base64") == nil)
    }
}

@Suite struct ShortsFeedTests {
    @Test func parsesTheSequenceWithDetails() async throws {
        let (items, next) = try await YouTubeService.parseShorts(
            first: try Fixture.data("descubrir/shorts-primero-web.json"),
            sequence: try Fixture.data("descubrir/shorts-secuencia-web.json"),
            details: ["shortprueba2": try Fixture.data("descubrir/shorts-detalle-web.json")])
        #expect(next == "secuenciaDePrueba2")
        // El tercero no tiene detalles (falló su pedido): no se muestra.
        #expect(items.map(\.videoId) == ["shortprueba1", "shortprueba2"])
        let first = items[0]
        #expect(first.isShort && first.kind == .video)
        #expect(first.title == "Short de prueba uno #prueba")
        #expect(first.author == "Canal de prueba")
        #expect(first.channelId == "UCcanaldeprueba000000001")
        #expect(first.viewCountText == "1,188,833 vistas")
        #expect(first.publishedText == "hace 17 horas")
        #expect(first.thumbnails.first?.url == "https://i.ytimg.com/vi/shortprueba1/sddefault.jpg")
        #expect(first.thumbnails.last?.height == 1920)
        #expect(!first.authorThumbnails.isEmpty)
        #expect(items[1].channelId == "UCcanaldeprueba000000002")
        #expect(items[1].thumbnails.last?.url == "https://i.ytimg.com/vi/shortprueba2/frame0.jpg")
    }
}

@Suite struct ChannelGroupImportTests {
    @Test func pocketTubeKeepsFileOrderAndSkipsBadIds() throws {
        let result = try #require(ChannelGroupImport.parse(try Fixture.data("descubrir/pockettube.json")))
        #expect(result.format == .pocketTube)
        #expect(result.groups.map(\.title) == ["Software libre", "Animación abierta", "Música / CC"])
        #expect(result.groups[1].channels.map(\.channelId) == ["UCz75RVbH8q2jdBJ4SnwuZZQ", "UCSMOQeBJ2RAnuFungnQOxLg"])
        #expect(result.skipped == 1)
        #expect(result.channelCount == 5)
        #expect(!result.isSubscriptions)
    }

    @Test func grayJayGroupsAreJSONStrings() throws {
        let result = try #require(ChannelGroupImport.parse(try Fixture.data("descubrir/grayjay_subscription_groups")))
        #expect(result.format == .grayJay)
        #expect(result.groups.map(\.title) == ["Películas abiertas", "Vacío"])
        let movies = result.groups[0]
        #expect(movies.iconURL?.hasPrefix("https://yt3.googleusercontent.com/") == true)
        #expect(movies.channels.map(\.channelId) == ["UCz75RVbH8q2jdBJ4SnwuZZQ", "UCSMOQeBJ2RAnuFungnQOxLg"])
        // Rumble, LBRY y un @handle (sin red no hay id) no cuentan.
        #expect(result.skipped == 3)
    }

    @Test func grayJayAlsoAcceptsPlainObjects() throws {
        let json = #"[{"id":"x","name":"Directo","urls":["https://m.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg"]}]"#
        let result = try #require(ChannelGroupImport.parse(Data(json.utf8)))
        #expect(result.groups.first?.channels.first?.channelId == "UCSMOQeBJ2RAnuFungnQOxLg")
    }

    @Test func newPipeIsSubscriptions() throws {
        let result = try #require(ChannelGroupImport.parse(try Fixture.data("descubrir/newpipe_subscriptions.json")))
        #expect(result.format == .newPipe)
        #expect(result.isSubscriptions)
        #expect(result.groups.first?.channels == [ImportedChannel(channelId: "UCSMOQeBJ2RAnuFungnQOxLg", title: "Blender"),
                                                  ImportedChannel(channelId: "UCz75RVbH8q2jdBJ4SnwuZZQ", title: "Blender Studio")])
        #expect(result.skipped == 1) // SoundCloud
    }

    @Test func unknownFilesAreRejected() {
        #expect(ChannelGroupImport.parse(Data(#"{"hola": 1}"#.utf8)) == nil)
        #expect(ChannelGroupImport.parse(Data("no es JSON".utf8)) == nil)
        #expect(ChannelGroupImport.parse(Data("[]".utf8)) == nil)
    }

    @Test func channelIdsFromURLs() {
        #expect(ChannelGroupImport.channelId(fromURL: "https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg") == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(ChannelGroupImport.channelId(fromURL: " UCSMOQeBJ2RAnuFungnQOxLg ") == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(ChannelGroupImport.channelId(fromURL: "https://www.youtube.com/@BlenderOfficial") == nil)
        #expect(ChannelGroupImport.channelId(fromURL: "https://evil.example/channel/UCSMOQeBJ2RAnuFungnQOxLg") == nil)
        #expect(ChannelGroupImport.channelId(fromURL: "https://www.youtube.com/channel/UCcorto") == nil)
    }
}
