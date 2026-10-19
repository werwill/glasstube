import Foundation
import Testing
@testable import YTKit

@Suite struct SearchTests {
    @Test func tvSearchIsGroupedInShelves() throws {
        let page = try Fixture.page("search-tv.json", api: .search, kind: .search)
        #expect(page.groups.map(\.title).contains("Shorts"))
        #expect(page.groups.count == 4)
        let results = page.groups[0]
        #expect(results.continuation?.api == .search)
        #expect(results.continuation?.surface == .tv)
        #expect(results.items.allSatisfy { $0.renderer == "lockupViewModel" })
        #expect(page.groups.first { $0.title == "Shorts" }?.isShorts == true)
        // La vista de TV no enlaza el canal en las tarjetas de búsqueda.
        #expect(results.items.filter { $0.kind == .video }.allSatisfy { $0.channelId == nil && $0.author != nil })
    }

    @Test func tvSearchContinuationBringsMoreShelves() throws {
        let page = try Fixture.page("search-tv-cont.json", api: .search, kind: .search)
        #expect(page.groups.count == 3)
        #expect(page.groups[0].continuation != nil)
    }

    @Test func webSearchResults() throws {
        let page = try Fixture.page("search-web.json", api: .search, kind: .search, looseTitle: "Resultados")
        let results = try #require(page.groups.first)
        #expect(results.title == "Resultados")
        #expect(results.renderer == "grid")
        #expect(results.continuation?.api == .search && results.continuation?.surface == .web)
        #expect(results.items.allSatisfy { $0.channelId?.hasPrefix("UC") == true && !$0.authorThumbnails.isEmpty })
        #expect(results.items.contains { $0.descriptionSnippet != nil })
        #expect(page.stats.ignored["officialCardViewModel"] == 1)
    }

    @Test func webSearchContinuation() throws {
        // onResponseReceivedCommands → appendContinuationItemsAction.
        let page = try Fixture.page("search-web-cont.json", api: .search, kind: .search)
        #expect(page.groups[0].renderer == "grid")
        #expect(page.groups[0].continuation != nil)
        let shorts = page.groups.filter(\.isShorts)
        #expect(!shorts.isEmpty)
        #expect(shorts.allSatisfy { $0.renderer == "gridShelfViewModel" && $0.title == "Shorts" })
        #expect(shorts.flatMap(\.items).allSatisfy { $0.renderer == "shortsLockupViewModel" && $0.viewCountText != nil })
    }

    @Test func webSearchWithChannels() throws {
        let page = try Fixture.page("search-web-mixed.json", api: .search, kind: .search)
        let channels = page.groups.flatMap(\.items).filter { $0.kind == .channel }
        #expect(channels.count == 3)
        let mrbeast = try #require(channels.first { $0.channelId == "UCX6OQ3DkcsbYNE6H8uQQuVA" })
        // `subscriberCountText` trae el @handle en los resultados WEB; se acomoda en `handle`.
        #expect(mrbeast.handle == "@MrBeast")
        #expect(mrbeast.subscriberCountText?.contains("@") == false)
        #expect(page.groups.contains { $0.title == "Lo más reciente de MrBeast" })
    }

    @Test func tvSearchWithChannels() throws {
        let page = try Fixture.page("search-tv-mixed.json", api: .search, kind: .search)
        let channels = page.groups.flatMap(\.items).filter { $0.kind == .channel }
        #expect(channels.count == 4)
        #expect(channels.allSatisfy { $0.channelId?.hasPrefix("UC") == true })
    }

    @Test func suggestions() throws {
        let suggestions = try SearchSuggestions.parse(try Fixture.data("suggestions-lofi.txt"))
        #expect(suggestions.count > 5)
        #expect(suggestions.allSatisfy { $0.lowercased().hasPrefix("lofi") })
        #expect(throws: (any Error).self) { try SearchSuggestions.parse(Data(")]}'\n{}".utf8)) }
    }

    @Test func suggestionsURL() {
        let url = SearchSuggestions.url(query: "lofi girl", locale: CatalogLocale(language: "es-419", region: "MX"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "clients1.google.com")
        #expect(items.first { $0.name == "client" }?.value == "youtube-lr")
        #expect(items.first { $0.name == "q" }?.value == "lofi girl")
        #expect(items.first { $0.name == "hl" }?.value == "es-419")
    }
}
