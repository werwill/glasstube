import Foundation
import Testing
@testable import YTKit

@Suite struct ChannelTests {
    static let mrbeast = "UCX6OQ3DkcsbYNE6H8uQQuVA"
    static let lofiGirl = "UCSJ4gkVC6NrvII8umztf0Ow"

    @Test func tabKindFromParams() {
        #expect(ChannelTab.Kind(params: "EghmZWF0dXJlZPIGBAoCMgA%3D") == .home)
        #expect(ChannelTab.Kind(params: "EgZ2aWRlb3PyBgQKAjoA") == .videos)
        #expect(ChannelTab.Kind(params: "EgZzaG9ydHPyBgUKA5oBAA%3D%3D") == .shorts)
        #expect(ChannelTab.Kind(params: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D") == .live)
        #expect(ChannelTab.Kind(params: "EglwbGF5bGlzdHPyBgQKAkIA") == .playlists)
        // Lofi Girl usa otro `params` para Listas: el nombre interno es el mismo.
        #expect(ChannelTab.Kind(params: "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA") == .playlists)
        #expect(ChannelTab.Kind(params: "Eghwb2RjYXN0c_IGBQoDugEA") == .podcasts)
        #expect(ChannelTab.Kind(params: nil) == .unknown)
        #expect(ChannelTab.Kind(params: "no es base64!") == .unknown)
        for kind in ChannelTab.Kind.allCases {
            if let params = kind.defaultParams { #expect(ChannelTab.Kind(params: params) == kind) }
        }
    }

    @Test func webHeaderAndTabs() throws {
        let page = try Fixture.channel("channel-web-home.json", id: Self.mrbeast)
        #expect(page.title == "MrBeast")
        #expect(page.handle == "@MrBeast")
        #expect(page.subscriberCountText?.isEmpty == false)
        #expect(page.videoCountText?.isEmpty == false)
        #expect(!page.avatar.isEmpty && !page.banner.isEmpty)
        #expect((page.description?.count ?? 0) > 100)
        #expect(page.selectedTab == .home)
        #expect(page.tabs.map(\.kind).starts(with: [.home, .videos, .shorts]))
        #expect(page.tabs.filter(\.isSelected).count == 1)
        #expect(page.content.groups.contains { $0.title == "New Uploads" })
        #expect(page.content.groups.flatMap(\.items).contains { $0.kind == .channel })
        #expect(page.content.stats.ignored["postRenderer"] != nil)
    }

    @Test func webVideosGridWithContinuation() throws {
        let page = try Fixture.channel("channel-web-videos.json", id: Self.mrbeast)
        #expect(page.selectedTab == .videos)
        let grid = try #require(page.content.groups.first)
        #expect(page.content.groups.count == 1)
        #expect(grid.title == page.tabs.first { $0.isSelected }?.title)
        #expect(grid.continuation?.api == .browse && grid.continuation?.surface == .web)
        #expect(grid.items.allSatisfy { $0.kind == .video && $0.durationSeconds != nil && $0.channelId == Self.mrbeast })

        let more = try Fixture.page("channel-web-videos-cont.json")
        #expect(more.groups.first?.items.count == 10)
        #expect(more.groups.first?.continuation != nil)
    }

    @Test func webShortsLiveAndPlaylists() throws {
        let shorts = try Fixture.channel("channel-web-shorts.json", id: Self.mrbeast)
        #expect(shorts.selectedTab == .shorts)
        #expect(shorts.content.groups.first?.isShorts == true)

        let live = try Fixture.channel("channel-web-live.json", id: Self.lofiGirl)
        #expect(live.selectedTab == .live)
        #expect(live.content.groups.first?.items.contains { $0.isLive } == true)

        let playlists = try Fixture.channel("channel-web-playlists.json", id: Self.lofiGirl)
        #expect(playlists.selectedTab == .playlists)
        let items = playlists.content.groups.flatMap(\.items)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.kind == .playlist && $0.playlistId?.hasPrefix("PL") == true && $0.videoCountText != nil })
        #expect(items.allSatisfy { $0.id == $0.playlistId })
    }

    @Test func missingTabFallsBackToHome() throws {
        // MrBeast no tiene pestaña de Listas: YouTube devuelve Inicio y así se informa.
        let page = try Fixture.channel("channel-web-missing-tab.json", id: Self.mrbeast)
        #expect(page.selectedTab == .home)
        #expect(!page.tabs.contains { $0.kind == .playlists })
    }

    @Test func tvChannelRows() throws {
        let page = try Fixture.channel("channel-tv.json", id: Self.mrbeast)
        #expect(page.title == "MrBeast")
        #expect(page.handle == "@MrBeast")
        #expect(page.subscriberCountText != nil)
        #expect(page.tabs.isEmpty)
        #expect(page.content.groups.count >= 6)
        #expect(page.content.groups.contains { $0.isShorts })
        #expect(page.content.groups.contains { $0.items.contains { $0.kind == .channel } })
        #expect(page.content.groups.contains { $0.continuation != nil })
    }
}

@Suite struct PlaylistTests {
    @Test func webPlaylistUsesContinuationItemViewModel() throws {
        let page = try Fixture.page("playlist-web.json")
        let list = try #require(page.groups.first)
        #expect(page.groups.count == 1)
        #expect(list.items.count == 10)
        #expect(list.items.allSatisfy { $0.kind == .video && $0.renderer == "lockupViewModel" && $0.durationSeconds != nil })
        // El token llega en `continuationItemViewModel.continuationCommand.innertubeCommand`.
        #expect(list.continuation?.api == .browse)
        let more = try Fixture.page("playlist-web-cont.json")
        #expect(more.groups.first?.items.isEmpty == false)

        let header = try Fixture.decode(PlaylistHeader.self, String(decoding: try Fixture.data("playlist-web.json"), as: UTF8.self))
        #expect(header.title == "autumn lofi")
    }

    @Test func tvPlaylistTwoColumns() throws {
        let page = try Fixture.page("playlist-tv.json")
        #expect(page.groups.first?.items.isEmpty == false)
        #expect(page.groups.first?.continuation?.surface == .tv)
        let header = try Fixture.decode(PlaylistHeader.self, String(decoding: try Fixture.data("playlist-tv.json"), as: UTF8.self))
        #expect(header.title == "autumn lofi")
    }
}
