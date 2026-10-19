import Foundation
import Testing
@testable import YTKit

/// Enlaces de YouTube y `glasstube://` (fase 4): pegar, arrastrar, el menú Servicios y el esquema propio.
@Suite struct LinkTests {
    @Test func understandsYouTubeLinks() {
        let cases: [(String, YouTubeLink)] = [
            ("https://www.youtube.com/watch?v=aqz-KE-bpKQ", .video(id: "aqz-KE-bpKQ")),
            ("https://youtube.com/watch?v=aqz-KE-bpKQ&t=90", .video(id: "aqz-KE-bpKQ", start: 90)),
            ("https://m.youtube.com/watch?v=aqz-KE-bpKQ&t=1m30s&list=PL6B3937A5D230E335",
             .video(id: "aqz-KE-bpKQ", start: 90, playlistId: "PL6B3937A5D230E335")),
            ("https://music.youtube.com/watch?v=aqz-KE-bpKQ", .video(id: "aqz-KE-bpKQ")),
            ("https://youtu.be/dQw4w9WgXcQ?si=abc&t=43", .video(id: "dQw4w9WgXcQ", start: 43)),
            ("youtu.be/dQw4w9WgXcQ", .video(id: "dQw4w9WgXcQ")),
            ("www.youtube.com/shorts/-MV7Hg31usU", .video(id: "-MV7Hg31usU")),
            ("https://www.youtube.com/live/p2AzyIEuFak?feature=share", .video(id: "p2AzyIEuFak")),
            ("https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ?start=10", .video(id: "aqz-KE-bpKQ", start: 10)),
            ("https://www.youtube.com/playlist?list=PLdkGTI2esnoY", .playlist(id: "PLdkGTI2esnoY")),
            ("https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg", .channel("UCSMOQeBJ2RAnuFungnQOxLg")),
            ("https://www.youtube.com/@BlenderOfficial/videos", .channel("@BlenderOfficial")),
            ("https://www.youtube.com/c/MKBHD", .channel("https://www.youtube.com/c/MKBHD")),
            ("https://www.youtube.com/results?search_query=lofi+hip+hop", .search("lofi hip hop")),
            ("https://www.youtube.com/attribution_link?u=/watch%3Fv%3Daqz-KE-bpKQ%26feature%3Dshare", .video(id: "aqz-KE-bpKQ")),
            ("vnd.youtube:aqz-KE-bpKQ", .video(id: "aqz-KE-bpKQ")),
            // Texto con el enlace en medio (Servicios, pegar).
            ("Mira esto: https://youtu.be/dQw4w9WgXcQ, está bueno", .video(id: "dQw4w9WgXcQ")),
            ("«https://www.youtube.com/watch?v=aqz-KE-bpKQ»", .video(id: "aqz-KE-bpKQ")),
        ]
        for (text, expected) in cases {
            #expect(YouTubeLink.parse(text) == expected, "\(text)")
        }
    }

    @Test func understandsTheGlasstubeScheme() {
        let cases: [(String, YouTubeLink)] = [
            ("glasstube://watch?v=aqz-KE-bpKQ&t=90", .video(id: "aqz-KE-bpKQ", start: 90)),
            ("glasstube://video/aqz-KE-bpKQ", .video(id: "aqz-KE-bpKQ")),
            ("glasstube://aqz-KE-bpKQ", .video(id: "aqz-KE-bpKQ")),
            ("glasstube://channel/UCSMOQeBJ2RAnuFungnQOxLg", .channel("UCSMOQeBJ2RAnuFungnQOxLg")),
            ("glasstube://channel/@BlenderOfficial", .channel("@BlenderOfficial")),
            ("glasstube://@BlenderOfficial", .channel("@BlenderOfficial")),
            ("glasstube://playlist?list=PLdkGTI2esnoY", .playlist(id: "PLdkGTI2esnoY")),
            ("glasstube://playlist/PLdkGTI2esnoY", .playlist(id: "PLdkGTI2esnoY")),
            ("glasstube://search?q=big%20buck%20bunny", .search("big buck bunny")),
            ("glasstube://open?url=https%3A%2F%2Fyoutu.be%2FdQw4w9WgXcQ", .video(id: "dQw4w9WgXcQ")),
            ("glasstube://www.youtube.com/watch?v=aqz-KE-bpKQ", .video(id: "aqz-KE-bpKQ")),
        ]
        for (text, expected) in cases {
            #expect(YouTubeLink.parse(text) == expected, "\(text)")
        }
        // Ida y vuelta por el esquema propio y por la web.
        for link in cases.map(\.1) + [.video(id: "aqz-KE-bpKQ", start: 90, playlistId: "PL6B3937A5D230E335"), .channel("https://www.youtube.com/c/MKBHD")] {
            #expect(YouTubeLink.parse(link.appURL) == link, "\(link.appURL)")
            #expect(YouTubeLink.parse(link.webURL) == link, "\(link.webURL)")
        }
    }

    @Test func rejectsWhatIsNotAYouTubeLink() {
        for text in ["", "hola", "https://example.com/watch?v=aqz-KE-bpKQ", "https://www.youtube.com/watch?v=corto",
                     "https://www.youtube.com/feed/subscriptions", "ftp://youtube.com/watch?v=aqz-KE-bpKQ", "glasstube://nada"] {
            #expect(YouTubeLink.parse(text) == nil, "\(text)")
        }
    }

    @Test func readsTimestamps() {
        #expect(YouTubeLink.seconds("90") == 90)
        #expect(YouTubeLink.seconds("90s") == 90)
        #expect(YouTubeLink.seconds("1h2m3s") == 3723)
        #expect(YouTubeLink.seconds("2m") == 120)
        #expect(YouTubeLink.seconds("1:02:03") == 3723)
        #expect(YouTubeLink.seconds("x") == nil)
    }
}
