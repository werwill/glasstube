import Foundation
import Testing
@testable import YTKit

/// Reglas que deben cumplir todas las respuestas grabadas: ningún renderer conocido falla al decodificarse y cada
/// elemento convertido tiene título, el id de su tipo y miniaturas https.
@Suite struct InvariantTests {
    static func api(for name: String) -> Continuation.API {
        name.hasPrefix("search") ? .search : (name.hasPrefix("next") ? .next : .browse)
    }

    @Test(arguments: Fixture.jsonNames)
    func everyItemIsUsable(_ name: String) throws {
        let page = try Fixture.page(name, api: Self.api(for: name))
        #expect(page.stats.failed.isEmpty, "renderers que fallaron: \(page.stats.failed)")
        #expect(page.stats.dropped.isEmpty, "elementos descartados: \(page.stats.dropped)")
        for item in page.groups.flatMap(\.items) {
            #expect(!item.title.isEmpty)
            switch item.kind {
            case .video: #expect(item.videoId?.count == 11, "\(name): \(item.title)")
            case .channel: #expect(item.channelId?.hasPrefix("UC") == true, "\(name): \(item.title)")
            case .playlist, .mix: #expect(item.playlistId != nil, "\(name): \(item.title)")
            }
            #expect(!item.thumbnails.isEmpty, "\(name): \(item.title) sin miniatura")
            #expect(item.thumbnails.allSatisfy { $0.url.hasPrefix("https://") })
        }
    }

    @Test func groupsHaveItems() throws {
        for name in Fixture.jsonNames {
            let page = try Fixture.page(name, api: Self.api(for: name))
            #expect(page.groups.allSatisfy { !$0.items.isEmpty }, "\(name) tiene filas vacías")
        }
    }
}
