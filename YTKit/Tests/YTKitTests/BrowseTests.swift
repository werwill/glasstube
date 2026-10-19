import Foundation
import Testing
@testable import YTKit

/// Inicio, Explorar y Tendencias sobre respuestas grabadas sin sesión.
@Suite struct BrowseTests {
    @Test(arguments: ["home-tv.json", "home-web.json"])
    func anonymousHomeIsOnlyANotice(_ name: String) throws {
        let page = try Fixture.page(name, kind: .home)
        #expect(page.isEmpty)
        #expect(page.notice?.isEmpty == false)
    }

    @Test func tvTopicRowsWithContinuations() throws {
        let page = try Fixture.page("topic-music-tv.json", kind: .topic)
        #expect(page.groups.count == 4)
        #expect(page.groups.allSatisfy { $0.title != nil && $0.renderer == "shelfRenderer" })
        // Cada fila sigue por su cuenta (horizontalListRenderer.continuations) y la página tiene más filas.
        #expect(page.groups.allSatisfy { $0.continuation?.surface == .tv && $0.continuation?.api == .browse })
        #expect(page.continuation != nil)
        let items = page.groups.flatMap(\.items)
        #expect(Set(items.map(\.kind)) == [.video, .playlist, .mix])
        // Primera fila: tiles del carrusel, sin `metadata` (título en `onFocusCommand`).
        let carousel = page.groups[0].items
        #expect(carousel.count == 6)
        #expect(carousel.allSatisfy { $0.videoId != nil && $0.author != nil && $0.durationText != nil })
        let video = try #require(items.first { $0.kind == .video && $0.publishedText != nil })
        #expect(video.channelId?.hasPrefix("UC") == true)
        #expect(video.viewCountText != nil)
        let album = try #require(items.first { $0.kind == .playlist })
        #expect(album.playlistId?.hasPrefix("OLAK") == true)
    }

    @Test func tvRowContinuationIsLooseItems() throws {
        let page = try Fixture.page("topic-news-tv-rowcont.json", kind: .topic)
        #expect(page.groups.count == 1)
        let row = page.groups[0]
        #expect(row.title == nil)
        #expect(row.items.count == 5)
        #expect(row.continuation != nil)
        #expect(row.items.contains { $0.isLive })
    }

    @Test func webTopicChannelRichShelves() throws {
        let page = try Fixture.page("topic-news-web.json", kind: .topic)
        #expect(page.groups.count == 10)
        #expect(page.groups.allSatisfy { $0.renderer == "richShelfRenderer" && $0.title != nil })
        let items = page.groups.flatMap(\.items)
        #expect(items.allSatisfy { $0.renderer == "videoRenderer" && $0.channelId != nil && !$0.authorThumbnails.isEmpty })
        #expect(items.contains { $0.isLive })
        #expect(items.filter { !$0.isLive }.allSatisfy { $0.durationSeconds != nil })
    }

    @Test func hypeLeaderboard() throws {
        let page = try Fixture.page("trending-hype-web.json", kind: .trending)
        #expect(page.groups.count == 9)
        #expect(page.groups.flatMap(\.items).allSatisfy { $0.renderer == "gridVideoRenderer" && $0.videoId != nil })
    }

    @Test func thumbnailSelection() {
        let thumbnails = [Thumbnail(url: "a", width: 168), Thumbnail(url: "b", width: 336), Thumbnail(url: "c", width: 720)]
        #expect(thumbnails.best(forWidth: 300)?.url == "b")
        #expect(thumbnails.best(forWidth: 2000)?.url == "c")
        var item = MediaItem(kind: .video, title: "t", renderer: "x")
        item.videoId = "abc"
        #expect(item.standardThumbnails.last?.url == "https://i.ytimg.com/vi/abc/maxresdefault.jpg")
    }
}
