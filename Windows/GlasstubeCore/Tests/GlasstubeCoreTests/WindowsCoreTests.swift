import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GlasstubeCore
import Testing
import YTKit

/// Lo que cambió al sacar la lógica de la app de Mac para Windows (sin AppKit ni SwiftUI).
@MainActor
@Suite struct WindowsCoreTests {
    @Test func navigatorGoesBackAndForward() {
        let navigator = Navigator()
        navigator.go(.section(.subscriptions))
        navigator.go(.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg", title: "Blender"))
        navigator.goBack()
        #expect(navigator.current == .section(.subscriptions))
        #expect(navigator.canGoForward)
        navigator.goForward()
        #expect(navigator.current == .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg", title: "Blender"))
        navigator.go(.section(.home))
        #expect(!navigator.canGoForward) // ir a otro lado borra «Adelante»
    }

    @Test func groupsMoveLikeSwiftUI() {
        let store = ChannelGroupStore(fileURL: nil)
        let a = store.create(title: "A"), b = store.create(title: "B"), c = store.create(title: "C")
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.groups.map(\.id) == [c.id, a.id, b.id])
        store.move(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        #expect(store.groups.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func remoteNameUsesTheComputerName() {
        #expect(AppSettings.defaultRemoteName.hasPrefix("Glasstube en "))
        #expect(AppSettings.defaultRemoteName.count > "Glasstube en ".count)
    }

    @Test func appearanceChangesReachTheInterface() {
        let settings = AppSettings()
        let original = settings.appearance
        var seen: [AppSettings.Appearance] = []
        settings.onAppearanceChange = { seen.append($0) }
        settings.appearance = .dark
        settings.appearance = original
        #expect(seen == [.dark, original])
    }

    @Test func sponsorColorsAreRGB() {
        let sponsor = SponsorSegment(start: 1, end: 2, category: "sponsor", uuid: "u")
        #expect(sponsor.color == RGBColor(red: 0.19, green: 0.82, blue: 0.35))
        #expect(SponsorSegment(start: 1, end: 2, category: "otra", uuid: "v").color == RGBColor(red: 0.6, green: 0.6, blue: 0.65))
        #expect(sponsor.skipTitle == "Saltar patrocinio")
    }

    @Test func downloadHandsThePageToTheInterface() async {
        let page = URL(string: "https://github.com/dueno/repo/releases/tag/v0.6.0")!
        let json = #"{"tag_name":"v0.6.0","html_url":"\#(page.absoluteString)","draft":false,"prerelease":false}"#
        let defaults = UserDefaults(suiteName: "GlasstubeCoreTests-\(UUID().uuidString)")!
        let checker = UpdateChecker(repository: "dueno/repo", currentVersion: "0.5.0", isEnabled: { true }, defaults: defaults,
                                    fetch: { request in
                                        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                                    })
        _ = await checker.check()
        #expect(checker.download() == page)
        #expect(checker.available == nil)
        #expect(checker.download() == nil)
    }
}
