import Foundation
import YTKit

// Fase 5a: feeds RSS, Shorts, filtros de búsqueda e importar grupos de canales.
extension CLI {
    static let discoverUsage = """

        Organizar y descubrir (fase 5a):
          ytkit rss <UC…>… [--refrescar]                  videos nuevos de esos canales por RSS (en paralelo, con caché)
          ytkit shorts [--pages N]                       feed de Shorts (WEB, sin cuenta)
          ytkit search <consulta…> --filtro tipo=video,fecha=semana,duracion=3-20,prioridad=popularidad,cc,4k,vivo
          ytkit importar <archivo>                       grupos de PocketTube, GrayJay o NewPipe
        """

    func rss(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        let ids = options.positional
        guard !ids.isEmpty else { throw CLIError("faltan los ids de canal (UC…)") }
        let start = Date()
        let result = await service.rssFeed(channelIds: ids, refresh: options.has("--refrescar"))
        let seconds = Date().timeIntervalSince(start)
        print("RSS: \(ids.count) canales, \(result.items.count) videos en \(String(format: "%.2f", seconds)) s; de caché \(result.cached), sin respuesta \(result.failed.count), fuera del límite \(result.skipped)")
        for (id, title) in result.channelTitles.sorted(by: { $0.key < $1.key }) { print("  · \(id) = \(title)") }
        if !result.failed.isEmpty { print("  sin respuesta: \(result.failed.joined(separator: ", "))") }
        printer.items(result.items)
        print("Shorts: \(result.items.filter(\.isShort).count)")
    }

    func shorts(_ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        let start = Date()
        let page = try await service.shorts()
        print(String(format: "(%.1f s)", Date().timeIntervalSince(start)))
        printer.page(page)
        try await paginate(service, page: page, pages: options.int("--pages") ?? 1, printer: printer)
    }

    func importGroups(_ options: Options) throws {
        guard let path = options.positional.first else { throw CLIError("falta el archivo") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let result = ChannelGroupImport.parse(data) else { throw CLIError("no es un archivo de PocketTube, GrayJay ni NewPipe") }
        print("\(result.format.rawValue): \(result.groups.count) grupos, \(result.channelCount) canales, \(result.skipped) entradas omitidas\(result.isSubscriptions ? " (suscripciones)" : "")")
        for group in result.groups {
            print("  ▸ \(group.title): \(group.channels.count) canales\(group.iconURL == nil ? "" : " (con ícono)")")
            for channel in group.channels.prefix(3) { print("     \(channel.channelId)\(channel.title.map { " \($0)" } ?? "")") }
        }
    }

    /// `--filtro tipo=video,fecha=semana,duracion=3-20,prioridad=popularidad,cc`.
    static func searchFilter(_ text: String) throws -> SearchFilter {
        var filter = SearchFilter()
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            switch (pair.first ?? "", pair.count > 1 ? pair[1] : "") {
            case ("tipo", "video"): filter.type = .video
            case ("tipo", "shorts"): filter.type = .shorts
            case ("tipo", "canal"): filter.type = .channel
            case ("tipo", "playlist"): filter.type = .playlist
            case ("tipo", "pelicula"): filter.type = .movie
            case ("fecha", "hoy"): filter.uploadDate = .today
            case ("fecha", "semana"): filter.uploadDate = .week
            case ("fecha", "mes"): filter.uploadDate = .month
            case ("fecha", "año"), ("fecha", "ano"): filter.uploadDate = .year
            case ("duracion", "<3"), ("duracion", "corta"): filter.duration = .underThree
            case ("duracion", "3-20"), ("duracion", "media"): filter.duration = .threeToTwenty
            case ("duracion", ">20"), ("duracion", "larga"): filter.duration = .overTwenty
            case ("prioridad", "popularidad"): filter.priority = .popularity
            case ("prioridad", "relevancia"): filter.priority = .relevance
            case ("cc", _): filter.features.insert(.creativeCommons)
            case ("4k", _): filter.features.insert(.uhd)
            case ("hd", _): filter.features.insert(.hd)
            case ("hdr", _): filter.features.insert(.hdr)
            case ("vivo", _): filter.features.insert(.live)
            case ("subtitulos", _): filter.features.insert(.subtitles)
            default: throw CLIError("filtro desconocido: \(part)")
            }
        }
        return filter
    }
}
