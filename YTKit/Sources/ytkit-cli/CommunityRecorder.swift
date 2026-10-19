import Foundation
import YTKit

/// `ytkit record-community <carpeta>`: graba las respuestas de prueba de la fase 3 (comentarios, respuestas, chat en vivo,
/// DeArrow y Return YouTube Dislike) en `Tests/YTKitTests/Fixtures/comunidad`, sin sesión.
///
/// Los comentarios y el chat son de personas: se cambian sus nombres (`@persona1`…), fotos (el avatar genérico de
/// YouTube), canales y textos (`Texto de prueba N`, conservando los emojis y la forma de los `runs`), y se quitan los
/// parámetros de los menús de cada mensaje. Se poda como en `ytkit record` y las listas se recortan a 8.
@MainActor
struct CommunityRecorder {
    let service: YouTubeService
    let directory: String?

    static let maxItems = 8
    static let defaultAvatar = "https://yt3.ggpht.com/a/default-user=s88-c-k-c0x00ffffff-no-rj"
    static let personKeys: Set<String> = ["authorText", "authorName"]
    static let photoKeys: Set<String> = ["authorThumbnail", "authorPhoto"]
    static let textKeys: Set<String> = ["contentText", "message", "headerSubtext"]
    static let droppedKeys: Set<String> = ["contextMenuEndpoint", "contextMenuAccessibility", "authorBadges", "replyButton"]

    var outputURL: URL { URL(fileURLWithPath: directory ?? "Tests/YTKitTests/Fixtures/comunidad", isDirectory: true) }

    func run(liveVideoId: String?) async throws {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let bunny = "aqz-KE-bpKQ"
        let meta = try await service.metadata(videoId: bunny, surface: .tv)
        guard let token = meta.commentsContinuation else { throw CLIError("Big Buck Bunny sin token de comentarios") }
        let first = try await save("comments-tv", "next", ["continuation": token])
        let page = try await YouTubeService.parseComments(first, replies: false)
        if let comment = page.comments.first(where: \.hasReplies), let replies = comment.repliesToken {
            try await save("comments-replies-tv", "next", ["continuation": replies])
        }
        if let newest = meta.commentSorts.dropFirst().first?.token {
            try await save("comments-newest-tv", "next", ["continuation": newest])
        }
        try await save("next-bunny-tv", "next", ["videoId": bunny], anonymize: false)

        if let liveVideoId {
            let live = try await service.metadata(videoId: liveVideoId, surface: .tv)
            if let chat = live.liveChatContinuation {
                try await save("chat-tv", "live_chat/get_live_chat", ["continuation": chat])
            } else {
                print("\(liveVideoId): sin chat en vivo; no se graba chat-tv")
            }
        }

        // DeArrow (por prefijo) y Return YouTube Dislike, recortados.
        let prefix = DeArrowClient.prefix(for: bunny)
        let (branding, _) = try await HTTP.shared.request(URL(string: "https://sponsor.ajay.app/api/branding/\(prefix)")!)
        if let all = try JSONSerialization.jsonObject(with: branding) as? [String: Any] {
            var kept: [String: Any] = [:]
            for key in all.keys.sorted().prefix(5) { kept[key] = all[key] }
            kept[bunny] = all[bunny]
            try write("dearrow-\(prefix)", JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        let (votes, _) = try await HTTP.shared.request(URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(bunny)")!)
        try write("dislikes-\(bunny)", votes)
    }

    @discardableResult
    func save(_ name: String, _ endpoint: String, _ fields: [String: String], anonymize: Bool = true) async throws -> Data {
        let raw = try await service.rawRequest(endpoint, surface: .tv, fields: fields)
        let pruned = try Recorder.prune(raw, keepFrameworkUpdates: !anonymize)
        // En el `next`, el adelanto de comentarios de la descripción trae a quien comentó: se quita.
        try write(name, anonymize ? try Self.anonymize(pruned) : try Self.dropping(Self.teaserKeys, from: pruned))
        return raw
    }

    func write(_ name: String, _ data: Data) throws {
        try data.write(to: outputURL.appendingPathComponent(name + ".json"))
        print("\(name).json: \(data.count) B")
    }

    static let teaserKeys: Set<String> = ["videoDescriptionCommentsSectionRenderer", "commentsEntryPointHeaderRenderer",
                                          "commentsEntryPointRenderer", "commentsEntryPointTeaserRenderer"]

    static func dropping(_ keys: Set<String>, from data: Data) throws -> Data {
        func walk(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, child) in dict where !keys.contains(key) { out[key] = walk(child) }
                return out
            }
            if let array = value as? [Any] { return array.map(walk) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: walk(try JSONSerialization.jsonObject(with: data)),
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func anonymize(_ data: Data) throws -> Data {
        var people: [String: Int] = [:]
        var texts = 0
        func person(_ name: String) -> Int {
            if let number = people[name] { return number }
            people[name] = people.count + 1
            return people.count
        }
        func replaceText(_ value: Any) -> Any {
            guard var dict = value as? [String: Any] else { return value }
            texts += 1
            if dict["simpleText"] != nil { dict["simpleText"] = "Texto de prueba \(texts)" }
            if let runs = dict["runs"] as? [[String: Any]] {
                var first = true
                dict["runs"] = runs.map { run -> [String: Any] in
                    guard run["text"] != nil else { return run } // emojis tal cual
                    defer { first = false }
                    return ["text": first ? "Texto de prueba \(texts)" : " más texto"]
                }
            }
            return dict
        }
        func walk(_ value: Any, key: String?) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                var number: Int?
                for personKey in personKeys {
                    if let author = (dict[personKey] as? [String: Any])?["simpleText"] as? String { number = person(author) }
                }
                for (key, child) in dict where !droppedKeys.contains(key) {
                    if personKeys.contains(key), let number {
                        out[key] = ["simpleText": "@persona\(number)"]
                    } else if photoKeys.contains(key) {
                        out[key] = ["thumbnails": [["url": defaultAvatar, "width": 88, "height": 88]]]
                    } else if key == "authorExternalChannelId" || (key == "browseId" && (child as? String)?.hasPrefix("UC") == true) {
                        out[key] = "UCpersona\(number ?? 0)_DE_PRUEBA"
                    } else if textKeys.contains(key) {
                        out[key] = replaceText(child)
                    } else {
                        out[key] = walk(child, key: key)
                    }
                }
                return out
            }
            if var array = value as? [Any] {
                if let key, ["contents", "actions"].contains(key), array.count > maxItems {
                    array = Array(array.prefix(maxItems))
                }
                return array.map { walk($0, key: nil) }
            }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: walk(json, key: nil), options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
