import Foundation

/// Registro de la app en %LOCALAPPDATA%\Glasstube\logs\glasstube.log: lo de YTKit (`Log.sink`), lo de la FFI y lo que
/// manda la interfaz con `gt_log`. Una app de ventana no tiene stderr, así que sin esto no queda rastro de nada.
/// Al arrancar, si pasa de 5 MB se renombra a glasstube.old.log.
final class FileLog: @unchecked Sendable {
    static let shared = FileLog()

    let directory: URL
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Glasstube").appendingPathComponent("logs")
        url = directory.appendingPathComponent("glasstube.log")
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            let old = directory.appendingPathComponent("glasstube.old.log")
            try? files.removeItem(at: old)
            try? files.moveItem(at: url, to: old)
        }
        if !files.fileExists(atPath: url.path) { _ = files.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ source: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) [\(source)] \(message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}

func log(_ message: String) { FileLog.shared.write("ffi", message) }
