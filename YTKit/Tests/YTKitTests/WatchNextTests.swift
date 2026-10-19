import Foundation
import Testing
@testable import YTKit

@Suite struct WatchNextTests {
    @Test(arguments: ["next-web.json", "next-tv.json"])
    func metadataFields(_ name: String) throws {
        let meta = try Fixture.metadata(name)
        #expect(meta.title == "Aprende Python - Curso completo para priincipiantes")
        #expect(meta.author == "freeCodeCamp.org")
        #expect(meta.channelId == "UC8butISFwT-Wl7EV0hUK0BQ")
        #expect(!meta.authorThumbnails.isEmpty)
        #expect(meta.subscriberCountText != nil)
        #expect(meta.viewCountText?.contains("49") == true)
        #expect(meta.likeCountText != nil)
        #expect(meta.publishedDate?.contains("2018") == true)
        #expect((meta.description?.count ?? 0) > 1000)
        #expect(meta.commentsContinuation != nil)
        #expect(meta.nextVideoId != nil)
    }

    @Test(arguments: ["next-web.json", "next-tv.json"])
    func chaptersAndHeatMap(_ name: String) throws {
        let meta = try Fixture.metadata(name)
        #expect(meta.chapters.count == 35)
        #expect(meta.chapters.first?.title == "Introducción")
        #expect(meta.chapters.first?.startMs == 0)
        #expect(meta.chapters[1].startMs == 105_000)
        #expect(meta.chapters.first?.durationMs == 105_000)
        #expect(zip(meta.chapters, meta.chapters.dropFirst()).allSatisfy { $0.startMs < $1.startMs })
        #expect(meta.heatMap.count == 100)
        #expect(meta.heatMap.allSatisfy { (0...1).contains($0.intensity) })
    }

    @Test func webSuggestionsAreOnePagedList() throws {
        let meta = try Fixture.metadata("next-web.json")
        #expect(meta.suggestions.count == 1)
        let list = meta.suggestions[0]
        #expect(list.kind == .suggestions)
        #expect(list.continuation?.api == .next && list.continuation?.surface == .web)
        #expect(list.items.allSatisfy { $0.videoId != nil })
        #expect(meta.suggestionsContinuation == nil)

        let more = try Fixture.page("next-web-cont.json", api: .next, kind: .suggestions)
        #expect(more.groups.first?.items.count == 10)
        #expect(more.groups.first?.continuation != nil)
    }

    @Test func tvSuggestionsAreRowsWithPageContinuation() throws {
        let meta = try Fixture.metadata("next-tv.json")
        #expect(meta.suggestions.count > 3)
        #expect(meta.suggestions.allSatisfy { $0.title == nil && $0.renderer == "shelfRenderer" })
        #expect(meta.suggestionsContinuation?.surface == .tv)
        #expect(meta.nextVideo?.videoId == meta.nextVideoId)

        let more = try Fixture.page("next-tv-cont.json", api: .next, kind: .suggestions)
        #expect(more.groups.count == 10)
    }
}
