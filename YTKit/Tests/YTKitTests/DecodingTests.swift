import Foundation
import Testing
@testable import YTKit

/// Tolerancia de los modelos: campos ausentes, tipos cambiados y renderers desconocidos o rotos.
@Suite struct DecodingTests {
    @Test func textInAllShapes() throws {
        let texts = try Fixture.decode([YTText].self, """
            ["cadena", {"simpleText": "simple"}, {"runs": [{"text": "a"}, {"text": "b"}]}, {"content": "vista"},
             {"runs": []}, {"accessibility": {"accessibilityData": {"label": "hace 8 años"}}, "simpleText": "hace 8 a"}]
            """)
        #expect(texts.map(\.string) == ["cadena", "simple", "ab", "vista", nil, "hace 8 a"])
        #expect(texts[5].accessibilityLabel == "hace 8 años")
    }

    @Test func channelIdFromRunsAndCommandRuns() throws {
        let texts = try Fixture.decode([YTText].self, """
            [{"runs": [{"text": "Lofi Girl", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCSJ4gkVC6NrvII8umztf0Ow"}}}]},
             {"content": "MrBeast", "commandRuns": [{"onTap": {"innertubeCommand": {"browseEndpoint": {"browseId": "UCX6OQ3DkcsbYNE6H8uQQuVA"}}}}]},
             {"content": "Ver lista", "commandRuns": [{"onTap": {"innertubeCommand": {"browseEndpoint": {"browseId": "VLPL123"}}}}]}]
            """)
        #expect(texts.map(\.channelId) == ["UCSJ4gkVC6NrvII8umztf0Ow", "UCX6OQ3DkcsbYNE6H8uQQuVA", nil])
    }

    @Test func numbersAsStringsOrDoubles() throws {
        let thumbs = try Fixture.decode([ThumbnailItem].self, """
            [{"url": "a", "width": 640, "height": "360"}, {"url": "b", "width": 1280.0}, {"url": "c", "width": "ancho"}]
            """)
        #expect(thumbs.map { $0.width?.value } == [640, 1280, nil])
        #expect(thumbs[0].height?.value == 360)
    }

    @Test func wrongTypesBecomeNilInsteadOfFailing() throws {
        // `title` es un número y `lengthSeconds` un objeto: el resto del video se lee igual.
        let video = try Fixture.decode(VideoRenderer.self, """
            {"videoId": "abc", "title": 42, "headline": {"simpleText": "Título"}, "lengthSeconds": {"x": 1},
             "thumbnail": {"thumbnails": [{"url": "//i.ytimg.com/vi/abc/hq.jpg", "width": 480}]}}
            """)
        let item = try #require(Convert.video(video, key: "videoRenderer"))
        #expect(item.title == "Título")
        #expect(item.videoId == "abc")
        #expect(item.durationSeconds == nil)
        #expect(item.thumbnails.first?.url == "https://i.ytimg.com/vi/abc/hq.jpg")
    }

    @Test func brokenItemDoesNotDropItsNeighbors() throws {
        // El segundo tile tiene `header` con otra forma y el tercero es un renderer que no existe.
        let container = try Fixture.decode(Container.self, """
            {"items": [
              {"tileRenderer": {"contentType": "TILE_CONTENT_TYPE_VIDEO", "onSelectCommand": {"watchEndpoint": {"videoId": "v1"}},
                                "metadata": {"tileMetadataRenderer": {"title": {"simpleText": "Uno"}}}}},
              {"tileRenderer": {"header": "roto", "onSelectCommand": {"watchEndpoint": {"videoId": "v2"}},
                                "metadata": {"tileMetadataRenderer": {"title": {"simpleText": "Dos"}}}}},
              {"rendererDelFuturo": {"items": [{"videoRenderer": {"videoId": "v3", "title": {"simpleText": "Tres"}}}]}},
              {"videoRenderer": {"videoId": "sin-título"}}
            ]}
            """)
        let result = PageExtractor(surface: .tv, api: .browse, kind: .unknown).extract(container.children)
        #expect(result.loose.map(\.videoId) == ["v1", "v2", "v3"])
        #expect(result.stats.dropped == ["videoRenderer": 1])
    }

    @Test func objectWithTwoRenderersVisitsBoth() throws {
        let node = try Fixture.decode(Node.self, """
            {"sectionListRenderer": {}, "richGridRenderer": {"contents": [
              {"richItemRenderer": {"content": {"videoRenderer": {"videoId": "x", "title": {"simpleText": "X"}}}}}]}}
            """)
        let result = PageExtractor(surface: .web, api: .browse, kind: .unknown).extract([node])
        #expect(result.loose.map(\.videoId) == ["x"])
    }

    @Test func noticeAndContinuationTokens() throws {
        let container = try Fixture.decode(Container.self, """
            {"contents": [
              {"feedNudgeRenderer": {"title": {"runs": [{"text": "Dale tu toque"}]}, "subtitle": {"simpleText": "Inicia sesión"}}},
              {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "T1"}}}}
            ], "continuations": [{"nextContinuationData": {"continuation": "T2"}}]}
            """)
        let page = PageExtractor(surface: .web, api: .browse, kind: .unknown).page([Node(key: "x", value: .container(container))])
        #expect(page.notice == "Dale tu toque. Inicia sesión")
        #expect(page.groups.isEmpty)
        #expect(page.continuation?.token == "T1")
        #expect(page.continuation?.surface == .web)
    }

    @Test func durations() {
        #expect(Convert.seconds(fromDuration: "4:19") == 259)
        #expect(Convert.seconds(fromDuration: "1:02:03") == 3723)
        #expect(Convert.seconds(fromDuration: "EN VIVO") == nil)
        #expect(Convert.seconds(fromDuration: "12") == nil)
    }
}
