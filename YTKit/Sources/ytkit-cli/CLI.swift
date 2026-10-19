import Foundation
import YTKit

/// Subcomandos de verificación de YTKit contra YouTube real, sin sesión.
@MainActor
struct CLI {
    let arguments: [String]

    static let usage = """
        ytkit — verificación de YTKit (catálogo de YouTube sin cuenta)

          ytkit home [--surface tv|web]                 Inicio (sin cuenta: armado con las filas de Explorar)
          ytkit trending                                 Tendencias (FEtrending o, si YouTube la retiró, Hype)
          ytkit topic <music|gaming|news|sports|live|movies> [--surface tv|web]
          ytkit search <consulta…> [--surface tv|web] [--pages N]
          ytkit suggest <texto…>                         sugerencias de búsqueda
          ytkit channel <UC…|@handle> [--tab home|videos|shorts|live|playlists|…] [--surface tv|web] [--pages N]
          ytkit playlist <PL…|RD…> [--surface tv|web] [--pages N]
          ytkit next <videoId> [--surface tv|web] [--pages N]
          ytkit comments <videoId> [--sort N] [--pages N] [--replies N]   comentarios (por TV), respuestas de los N primeros
          ytkit chat <videoId> [--seconds N]             chat en vivo de un directo durante N s (30 por omisión)
          ytkit dearrow <videoId…>                       títulos y miniaturas de DeArrow (por prefijo de hash)
          ytkit dislikes <videoId>                       votos de Return YouTube Dislike
          ytkit record-community [carpeta] [--live id]   graba las fixtures de comentarios, chat, DeArrow y RYD (anonimizadas)
          ytkit compare [--query q] [--video id]         TV contra WEB en Inicio, búsqueda y next
          ytkit formats <videoId> [--start CLIENTE] [--potoken]   streams con la rotación de clientes
          ytkit sabr-player <videoId…> [--veces N] [--cuenta] [--sin-recuperar] [--bajar] [--simular-bot N]   player de SABR como la app
          ytkit record <carpeta> [nombre…]               graba las respuestas de prueba (todas o solo esas)
          ytkit raw <browse|search|next> <tv|web> clave=valor…   respuesta cruda de Innertube (diagnóstico)
          ytkit lounge [--seconds N] [--nombre X] [--mostrar] [--sin-codigo] [--guardar]   pantalla de Lounge (control remoto)
          ytkit link <texto…>                            cómo se interpreta un enlace de YouTube o glasstube://

        Opciones: --json (modelos en JSON), --rows N y --items N (cuánto se imprime), --hl es-419 --gl MX, -v
        """

    func run() async -> Int32 {
        var options = Options(arguments)
        guard let command = options.positional.first else {
            print(Self.usage + Self.accountUsage)
            return 1
        }
        options.positional.removeFirst()
        Log.verbose = options.has("-v")
        do {
            let locale = CatalogLocale(language: options.value("--hl") ?? CatalogLocale.current.language,
                                       region: options.value("--gl") ?? CatalogLocale.current.region)
            // La sesión (Llavero) solo se abre si hace falta: leerlo puede pedir permiso al sistema.
            let withAccount = Self.accountCommands.contains(command) || options.has("--cuenta")
            let session = withAccount ? try AccountManager(locale: locale, ephemeral: options.has("--sin-llavero")) : nil
            // El catálogo ya no lee el Llavero por su cuenta (ver `AccountManager.knownSignedIn`): se lee aquí.
            if let session { _ = try? await session.load() }
            let service = try YouTubeService(locale: locale, session: session)
            let printer = Printer(rows: options.int("--rows") ?? 12, items: options.int("--items") ?? 4, json: options.has("--json"))
            switch command {
            case "home": try await home(service, options, printer)
            case "trending": printer.page(try await service.trending())
            case "topic": try await topic(service, options, printer)
            case "search": try await search(service, options, printer)
            case "suggest": try await suggest(service, options)
            case "channel": try await channel(service, options, printer)
            case "playlist": try await playlist(service, options, printer)
            case "next": try await next(service, options, printer)
            case "comments": try await comments(service, options, printer)
            case "chat": try await chat(service, options)
            case "dearrow": await dearrow(options)
            case "dislikes": try await dislikes(options)
            case "record-community":
                try await CommunityRecorder(service: service, directory: options.positional.first).run(liveVideoId: options.value("--live"))
            case "compare": try await Compare(service: service, options: options).run()
            case "formats": return await formats(service, options)
            case "sabr-player": return await sabrPlayer(service, options)
            case "record":
                try await Recorder(service: service, directory: options.positional.first,
                                   only: Set(options.positional.dropFirst())).run()
            case "raw": try await raw(service, options)
            case "lounge": try await lounge(options)
            case "link": link(options)
            case "parse":
                // Respuesta guardada → modelos, sin red ni Llavero (diagnóstico de fixtures y crudas).
                guard let path = options.positional.first else { throw CLIError("falta el archivo") }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let surface = try surface(options, path.contains("-tv") ? .tv : .web)
                if options.has("--next") {
                    printer.metadata(try await YouTubeService.parseMetadata(data, videoId: options.value("--video") ?? "?", surface: surface))
                } else {
                    printer.page(try await YouTubeService.parsePage(data, surface: surface, api: .browse, kind: .unknown, looseTitle: "(cuadrícula)"))
                }
            case "sanitize":
                guard let crudas = options.positional.first else { throw CLIError("falta la carpeta de crudas") }
                try AccountRecorder.sanitizeDirectory(crudas, into: URL(fileURLWithPath: options.positional.dropFirst().first ?? "Tests/YTKitTests/Fixtures"))
            case _ where Self.accountCommands.contains(command): try await runAccount(command, service, options, printer)
            default:
                print(Self.usage + Self.accountUsage)
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 2
        }
    }

    func surface(_ options: Options, _ fallback: Surface) throws -> Surface {
        guard let raw = options.value("--surface") else { return fallback }
        guard let surface = Surface(rawValue: raw.lowercased()) else { throw CLIError("--surface debe ser tv o web") }
        return surface
    }

    func home(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        // Con --cuenta y sin --surface, el Inicio de la cuenta (por TV).
        if options.has("--cuenta"), options.value("--surface") == nil {
            printer.page(try await service.home())
            return
        }
        let surface = try surface(options, service.preferences.home)
        printer.page(try await service.home(surface: surface))
    }

    func topic(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        guard let name = options.positional.first, let topic = Topic(rawValue: name) else {
            throw CLIError("tema: \(Topic.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let surface = try surface(options, service.preferences.topics)
        printer.page(try await service.topic(topic, surface: surface))
    }

    func search(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        let query = options.positional.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError("falta la consulta") }
        let surface = try surface(options, service.preferences.search)
        let page = try await service.search(query, surface: surface)
        printer.page(page)
        try await paginate(service, page: page, pages: options.int("--pages") ?? 1, printer: printer)
    }

    func suggest(_ service: YouTubeService, _ options: Options) async throws {
        let query = options.positional.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError("falta el texto") }
        let suggestions = try await service.searchSuggestions(query)
        print("Sugerencias para «\(query)» (\(suggestions.count)):")
        for suggestion in suggestions { print("  · \(suggestion)") }
    }

    func channel(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        guard let id = options.positional.first else { throw CLIError("falta el canal (UC… o @handle)") }
        let tabName = options.value("--tab") ?? "home"
        guard let tab = ChannelTab.Kind(rawValue: tabName) else {
            throw CLIError("pestaña: \(ChannelTab.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let surface = try surface(options, service.preferences.channel)
        let page = try await service.channel(id, tab: tab, surface: surface)
        printer.channel(page, requested: tab)
        try await paginate(service, page: page.content, pages: options.int("--pages") ?? 1, printer: printer)
    }

    func playlist(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        guard let id = options.positional.first else { throw CLIError("falta el id de la lista") }
        let surface = try surface(options, service.preferences.channel)
        let page = try await service.playlist(id, surface: surface)
        printer.page(page)
        try await paginate(service, page: page, pages: options.int("--pages") ?? 1, printer: printer)
    }

    func next(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        guard let videoId = options.positional.first else { throw CLIError("falta el videoId") }
        let surface = try surface(options, service.preferences.next)
        let meta = try await service.metadata(videoId: videoId, surface: surface)
        printer.metadata(meta)
        let pages = options.int("--pages") ?? 1
        guard pages > 1 else { return }
        if let row = meta.suggestions.first(where: { $0.continuation != nil }) {
            var group = row
            for page in 2...pages {
                group = try await service.continueGroup(group)
                print("\n-- sugeridos, página \(page) (continueGroup): \(group.items.count) elementos, continuación \(group.continuation == nil ? "no" : "sí")")
                printer.items(group.items)
                if group.continuation == nil { break }
            }
        } else if var continuation = meta.suggestionsContinuation {
            for page in 2...pages {
                let next = try await service.continuePage(continuation)
                print("\n-- sugeridos, página \(page) (continuePage): \(next.groups.count) filas, \(next.itemCount) elementos")
                printer.page(next, header: false)
                guard let more = next.continuation else { break }
                continuation = more
            }
        }
    }

    /// Pide más con la continuación de la primera fila que la tenga (`continueGroup`) o la de la página (`continuePage`).
    func paginate(_ service: YouTubeService, page: BrowsePage, pages: Int, printer: Printer) async throws {
        guard pages > 1 else { return }
        if let row = page.groups.first(where: { $0.continuation != nil }) {
            var group = row
            for number in 2...pages {
                group = try await service.continueGroup(group)
                print("\n-- «\(group.title ?? "(sin título)")», página \(number) (continueGroup): \(group.items.count) elementos, continuación \(group.continuation == nil ? "no" : "sí")")
                printer.items(group.items)
                if group.continuation == nil { break }
            }
        } else if var continuation = page.continuation {
            for number in 2...pages {
                let next = try await service.continuePage(continuation)
                print("\n-- página \(number) (continuePage): \(next.groups.count) filas, \(next.itemCount) elementos")
                printer.page(next, header: false)
                guard let more = next.continuation else { break }
                continuation = more
            }
        } else {
            print("\n(sin continuación)")
        }
    }

    /// Comentarios por TV con el token del `next` (o el de un orden con `--sort N`), sus páginas y respuestas.
    func comments(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        guard let videoId = options.positional.first else { throw CLIError("falta el videoId") }
        let meta = try await service.metadata(videoId: videoId)
        print("\(meta.title ?? videoId) · \(meta.commentsCountText ?? "?") comentarios · órdenes: \(meta.commentSorts.map(\.title).joined(separator: ", "))")
        let sortIndex = options.int("--sort")
        guard var token = sortIndex.flatMap({ meta.commentSorts.indices.contains($0) ? meta.commentSorts[$0].token : nil })
            ?? meta.commentsContinuation else {
            print("(sin comentarios: desactivados o sin token)")
            return
        }
        var all: [Comment] = []
        for number in 1...max(1, options.int("--pages") ?? 1) {
            let page = try await service.comments(token)
            print("\n-- página \(number): \(page.comments.count) comentarios, continuación \(page.continuation == nil ? "no" : "sí")")
            printer.comments(page.comments)
            all += page.comments
            guard let next = page.continuation else { break }
            token = next
        }
        for comment in all.filter(\.hasReplies).prefix(options.int("--replies") ?? 0) {
            let page = try await service.replies(to: comment)
            print("\n-- respuestas a \(comment.author.prefix(2))… (\(comment.replyCountText ?? "?")): \(page.comments.count), original \(page.parent?.id == comment.id ? "sí" : "no"), continuación \(page.continuation == nil ? "no" : "sí")")
            printer.comments(page.comments)
        }
    }

    /// Chat en vivo con el sondeo de `liveChatUpdates`, durante `--seconds`.
    func chat(_ service: YouTubeService, _ options: Options) async throws {
        guard let videoId = options.positional.first else { throw CLIError("falta el videoId") }
        let meta = try await service.metadata(videoId: videoId)
        guard let token = meta.liveChatContinuation else {
            print("\(meta.title ?? videoId): sin chat en vivo (¿no es un directo?)")
            return
        }
        print("\(meta.title ?? videoId) · chat\(meta.isLiveChatReplay ? " (repetición)" : "")")
        let seconds = Double(options.int("--seconds") ?? 30)
        let start = Date()
        var total = 0, removed = 0, updates = 0
        let task = Task {
            for try await update in service.liveChatUpdates(token) {
                updates += 1
                total += update.messages.count
                removed += update.removedIds.count
                let elapsed = Date().timeIntervalSince(start)
                print(String(format: "-- %5.1f s: %d mensajes, %d quitados", elapsed, update.messages.count, update.removedIds.count))
                for message in update.messages.prefix(3) {
                    let extra = [message.kind == .text ? nil : message.kind.rawValue, message.amountText].compactMap { $0 }.joined(separator: " ")
                    print("   \(message.author.prefix(1))…: \(message.text.prefix(80))\(extra.isEmpty ? "" : " [\(extra)]")")
                }
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        task.cancel()
        print("\n\(updates) tandas, \(total) mensajes, \(removed) quitados en \(Int(seconds)) s")
    }

    func dearrow(_ options: Options) async {
        let ids = options.positional
        let found = await DeArrowClient.shared.branding(for: ids)
        for id in ids {
            let branding = found[id]
            print("\(id): título \(branding?.title.map { "«\($0)»" } ?? "(el de YouTube)") · miniatura \(branding?.thumbnailTime.map { String(format: "en %.1f s", $0) } ?? "(la de YouTube)")")
            if let url = branding?.thumbnailURL { print("   \(url.absoluteString)") }
        }
    }

    func dislikes(_ options: Options) async throws {
        guard let videoId = options.positional.first else { throw CLIError("falta el videoId") }
        let votes = try await DislikeClient.shared.votes(videoId: videoId)
        print("\(videoId): \(DislikeClient.compact(votes.likes)) me gusta · \(DislikeClient.compact(votes.dislikes)) no me gusta (\(votes.dislikes)) · \(votes.likeRatio.map { String(format: "%.0f %%", $0 * 100) } ?? "-")")
    }

    func raw(_ service: YouTubeService, _ options: Options) async throws {
        guard options.positional.count >= 2, let surface = Surface(rawValue: options.positional[1]) else {
            throw CLIError("uso: ytkit raw <browse|search|next> <tv|web> clave=valor…")
        }
        var fields: [String: String] = [:]
        for pair in options.positional.dropFirst(2) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        let data = try await service.rawRequest(options.positional[0], surface: surface, fields: fields)
        FileHandle.standardOutput.write(data)
    }

    func formats(_ service: YouTubeService, _ options: Options) async -> Int32 {
        guard let videoId = options.positional.first else {
            print("falta el videoId")
            return 1
        }
        var resolveOptions = ResolveOptions()
        resolveOptions.startClient = options.value("--start")
        resolveOptions.allowPoToken = options.has("--potoken")
        let resolver = options.has("--potoken")
            ? StreamResolver(catalog: service.catalog, poTokenSource: PoTokenWebViewProvider(catalog: service.catalog))
            : StreamResolver(catalog: service.catalog, poTokenSource: nil)
        print("Resolviendo \(videoId) (rotación desde \(resolveOptions.startClient ?? service.catalog.defaultStart))…")
        let report = await resolver.resolve(videoId: videoId, options: resolveOptions)
        guard let chosen = report.chosen, let video = chosen.video, let audio = chosen.audio else {
            print("Ningún cliente dio streams reproducibles.")
            return 2
        }
        print("\n«\(report.title ?? videoId)» de \(report.author ?? "?") — cliente \(chosen.client.id)")
        print("  video: itag \(video.itag) \(video.codec.rawValue) \(video.label) (\(video.container))")
        print("  audio: itag \(audio.itag) \(audio.codec.rawValue) \(audio.label) (\(audio.container))")
        return 0
    }
}

extension CLI {
    /// El `player` de una sesión SABR (cliente TV con su PoToken), como lo pide la app al abrir un video, N veces por
    /// video y con un solo proveedor de PoToken (como la app). Imprime el estado de cada intento.
    func sabrPlayer(_ service: YouTubeService, _ options: Options) async -> Int32 {
        guard !options.positional.isEmpty, let tv = service.catalog.profile("TV") else {
            print("faltan los videoId")
            return 1
        }
        let provider = PoTokenWebViewProvider(catalog: service.catalog)
        var failures = 0, total = 0
        for round in 1...(options.int("--veces") ?? 1) {
            for videoId in options.positional {
                total += 1
                var sabr = SabrOptions()
                sabr.logRequests = false
                sabr.retainSegments = false
                sabr.targetSeconds = 4
                sabr.recoverLoginRequired = !options.has("--sin-recuperar")
                sabr.simulatedLoginRequired = options.int("--simular-bot") ?? 0
                let (ok, line) = await Self.probePlayer(videoId: videoId, client: tv, options: sabr, provider: provider,
                                                        account: service.session, download: options.has("--bajar"))
                if !ok { failures += 1 }
                print("\(round) · \(line)")
            }
        }
        print("\(total - failures) de \(total) bien")
        return failures == 0 ? 0 : 2
    }
}

extension CLI {
    /// Un intento de `sabr-player`, fuera del actor principal (la sesión SABR no es `Sendable`).
    nonisolated static func probePlayer(videoId: String, client: ClientProfile, options: SabrOptions, provider: PoTokenSource,
                                        account: AccountManager?, download: Bool) async -> (Bool, String) {
        let session = SabrSession(videoId: videoId, client: client, options: options, poTokenSource: provider)
        session.account = account
        session.onEvent = { print("    \($0)") }
        let start = Date()
        do {
            // Con descarga: además unos segundos de video y audio (que ese player sirva para SABR).
            if download { try await session.run() } else { try await session.prepare() }
            let seconds = [session.video, session.audio].compactMap { $0?.bufferedMs }.map { "\($0 / 1000) s" }
            return (true, String(format: "%@ OK en %.1f s%@%@%@", videoId, Date().timeIntervalSince(start),
                                 session.playerSignedIn ? " · con la cuenta" : " · anónimo",
                                 session.playerAttempts > 1 ? " · 2.º intento (\(session.playerRecoveries.joined(separator: ", ")))" : "",
                                 download ? " · bajado \(seconds.joined(separator: " / "))" : ""))
        } catch {
            return (false, String(format: "%@ FALLÓ en %.1f s: %@", videoId, Date().timeIntervalSince(start), "\(error)"))
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var positional: [String] = []
    private var flags: [String: String] = [:]
    private static let valued: Set<String> = ["--surface", "--rows", "--items", "--pages", "--tab", "--hl", "--gl",
                                              "--query", "--video", "--start", "--crudo", "--sort", "--replies", "--seconds", "--live", "--veces", "--simular-bot", "--nombre"]

    init(_ arguments: [String]) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if Self.valued.contains(argument) {
                flags[argument] = iterator.next() ?? ""
            } else if argument.hasPrefix("--") || argument == "-v" {
                // Solo "--…" y "-v": un videoId puede empezar con "-" (-MV7Hg31usU).
                flags[argument] = ""
            } else {
                positional.append(argument)
            }
        }
    }

    func has(_ flag: String) -> Bool { flags[flag] != nil }
    func value(_ flag: String) -> String? { flags[flag].flatMap { $0.isEmpty ? nil : $0 } }
    func int(_ flag: String) -> Int? { value(flag).flatMap(Int.init) }
}
