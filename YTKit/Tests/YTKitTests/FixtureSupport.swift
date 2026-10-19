import Foundation
@testable import YTKit

/// Carga las respuestas grabadas (`ytkit record Tests/YTKitTests/Fixtures`) y las convierte igual que el servicio, en
/// el hilo de pila grande.
enum Fixture {
    static let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static var jsonNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }.sorted()
    }

    static func surface(of name: String) -> Surface { name.contains("-tv") ? .tv : .web }

    static func page(_ name: String, api: Continuation.API = .browse, kind: MediaGroup.Kind = .unknown,
                     looseTitle: String? = nil) throws -> BrowsePage {
        let data = try data(name)
        let surface = surface(of: name)
        return try InnertubeDecoding.runSync {
            let response = try JSONDecoder().decode(InnertubeResponse.self, from: data)
            return PageExtractor(surface: surface, api: api, kind: kind).page(response.roots, looseTitle: looseTitle)
        }
    }

    static func channel(_ name: String, id: String) throws -> ChannelPage {
        let data = try data(name)
        let surface = surface(of: name)
        return try InnertubeDecoding.runSync { try ChannelParser.page(channelId: id, data: data, surface: surface) }
    }

    static func metadata(_ name: String, videoId: String = "rfscVS0vtbw") throws -> MediaItemMetadata {
        let data = try data(name)
        let surface = surface(of: name)
        return try InnertubeDecoding.runSync {
            WatchNextParser.metadata(videoId: videoId, response: try JSONDecoder().decode(WatchNextResponse.self, from: data),
                                     surface: surface)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try InnertubeDecoding.runSync { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    }
}
