import Foundation
import YTKit

// Diagnóstico de los streams elegidos: lo que importa de cada URL para saber si YouTube la va a frenar (n, pot,
// ratebypass, sabr, clen…) va siempre al registro, sin la URL. Las URLs completas, para medirlas con curl, las guarda
// la app con `--volcar-urls`.

enum StreamDiagnostics {
    /// "itag 248 vp9 1920x1080@30 · 2.6 Mb/s · clen 12.3 MB · n sí (12 car.) · pot no · ratebypass no · sabr no".
    static func summary(_ format: StreamFormat?) -> String {
        guard let format, let url = format.url, let components = URLComponents(string: url) else { return "sin URL" }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func yes(_ name: String) -> String { value(name) != nil ? "sí" : "no" }
        let megabytes = format.contentLength.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "?"
        let rate = String(format: "%.2f Mb/s", Double(format.bitrate) / 1_000_000)
        return "itag \(format.itag) \(format.codec.rawValue) \(format.label) · \(rate) · clen \(megabytes) · host \(components.host ?? "?") · "
            + "n \(value("n").map { "sí (\($0.count) car.)" } ?? "no") · pot \(yes("pot")) · ratebypass \(yes("ratebypass")) · "
            + "sabr \(yes("sabr")) · c \(value("c") ?? "?") · expire \(value("expire") ?? "?")"
    }
}
