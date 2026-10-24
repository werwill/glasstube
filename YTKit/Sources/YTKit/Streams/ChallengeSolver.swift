import Foundation

public struct ChallengeError: Error, CustomStringConvertible {
    public let description: String
    init(_ message: String) { description = message }
}

/// Resultado de una tanda de desafíos para un player.
public struct SolveResult: Sendable {
    public var n: [String: String] = [:]
    public var sig: [String: String] = [:]
    public var nError: String?
    public var sigError: String?
    /// Segundos dentro del motor de JavaScript (incluye parsear el player con meriyah si no estaba en caché).
    public var jsSeconds: TimeInterval = 0
    public var usedPreprocessedCache = false
}

/// Solver de firma y parámetro `n` sobre JavaScriptCore (QuickJS fuera de Apple, ver `ScriptEngine`) con los scripts de yt-dlp/ejs que trae SmartTube
/// (`V8ChallengeProvider` + `JsRuntimeChalBaseJCP`) y el solver de players TCL (`TclChallengeProvider`).
/// Un motor por tipo de solver, reutilizado; el actor serializa el acceso.
public actor ChallengeSolver {
    public static let shared = ChallengeSolver()

    private static let ejsSection = "challenge-solver"
    private static let tclSection = "tcl-challenge-solver"
    private static let libFiles = ["polyfill.js", "meriyah-6.1.4.min.js", "astring-1.9.0.min.js"]

    private var ejsContext: ScriptEngine?
    private var tclContext: ScriptEngine?

    // MARK: - yt-dlp/ejs (players web y tv normales)

    public func solve(playerURL: String, playerCode: @Sendable () async throws -> String,
                      n: [String], sig: [String]) async throws -> SolveResult {
        let n = Array(Set(n)), sig = Array(Set(sig))
        var result = SolveResult()
        guard !(n.isEmpty && sig.isEmpty) else { return result }

        let context = try ejsContextLoaded()
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }

        let cacheKey = "player:\(playerURL)"
        var input: [String: Any]
        if let preprocessed = DiskCache.load(section: Self.ejsSection, key: cacheKey) {
            input = ["type": "preprocessed", "preprocessed_player": preprocessed, "requests": requests]
            result.usedPreprocessedCache = true
        } else {
            input = ["type": "player", "player": try await playerCode(), "requests": requests, "output_preprocessed": true]
        }

        let start = Date()
        let output: [String: Any]
        do {
            output = try run(context, entry: "jsc", input: input)
        } catch {
            // Igual que SmartTube (`ie.cache.clear`): la caché preprocesada podría estar rota.
            if result.usedPreprocessedCache { DiskCache.clear(section: Self.ejsSection) }
            throw error
        }
        result.jsSeconds = Date().timeIntervalSince(start)

        if output["type"] as? String == "error" {
            if result.usedPreprocessedCache { DiskCache.clear(section: Self.ejsSection) }
            throw ChallengeError("solver: \(output["error"] as? String ?? "error desconocido")")
        }
        if let preprocessed = output["preprocessed_player"] as? String {
            DiskCache.store(section: Self.ejsSection, key: cacheKey, value: preprocessed)
        }

        let responses = output["responses"] as? [[String: Any]] ?? []
        for (request, response) in zip(requests, responses) {
            let type = request["type"] as! String
            if response["type"] as? String == "error" {
                let message = (response["error"] as? String).map { String($0.prefix(400)) } ?? "error"
                if type == "n" { result.nError = message } else { result.sigError = message }
                continue
            }
            let data = response["data"] as? [String: String] ?? [:]
            if type == "n" { result.n = data } else { result.sig = data }
        }
        return result
    }

    // MARK: - TCL (tv-player-ias-tcl): solo `n`, con la URL completa como desafío

    public func solveTCL(playerURL: String, playerCode: @Sendable () async throws -> String, n: [String]) async throws -> SolveResult {
        var result = SolveResult()
        let n = Array(Set(n))
        guard !n.isEmpty else { return result }
        let context = try tclContextLoaded()

        // El n-function TCL recibe un objeto URL y muta su parámetro "n" (TclChallengeProvider.solveN).
        let challengeByParam = Dictionary(uniqueKeysWithValues: n.map { ($0, "https://www.youtube.com/videoplayback?n=\($0)") })
        let cacheKey = "player:\(playerURL)"
        var input: [String: Any]
        if let preprocessed = DiskCache.load(section: Self.tclSection, key: cacheKey) {
            input = ["type": "preprocessed", "preprocessed_player": preprocessed, "challenges": Array(challengeByParam.values)]
            result.usedPreprocessedCache = true
        } else {
            input = ["type": "player", "player": try await playerCode(), "challenges": Array(challengeByParam.values), "output_preprocessed": true]
        }

        let start = Date()
        let output = try run(context, entry: "tclSolver", input: input)
        result.jsSeconds = Date().timeIntervalSince(start)
        if output["type"] as? String == "error" {
            if result.usedPreprocessedCache { DiskCache.clear(section: Self.tclSection) }
            result.nError = output["error"] as? String ?? "error desconocido"
            return result
        }
        if let preprocessed = output["preprocessed_player"] as? String {
            DiskCache.store(section: Self.tclSection, key: cacheKey, value: preprocessed)
        }
        let results = output["results"] as? [String: String] ?? [:]
        for (param, challenge) in challengeByParam {
            // El solver devuelve la URL ya transformada o el valor de n; normalizamos a solo n.
            if let value = results[challenge] {
                result.n[param] = value.hasPrefix("http") ? (URLComponents(string: value)?.value("n") ?? value) : value
            }
        }
        return result
    }

    // MARK: - Motor de JavaScript

    /// Los scripts de yt-dlp/ejs y del solver TCL.
    static var resourceDirectory: URL { Bundle.module.url(forResource: "nsigsolver", withExtension: nil)! }

    /// Carga los dos solvers en su motor sin resolver nada (pruebas y precalentado).
    func warmUp() throws {
        _ = try ejsContextLoaded()
        _ = try tclContextLoaded()
    }

    private func ejsContextLoaded() throws -> ScriptEngine {
        if let ejsContext { return ejsContext }
        let context = try makeContext(files: Self.libFiles + ["yt.solver.core.js"])
        ejsContext = context
        return context
    }

    private func tclContextLoaded() throws -> ScriptEngine {
        if let tclContext { return tclContext }
        let context = try makeContext(files: Self.libFiles + ["tcl.solver.js"])
        tclContext = context
        return context
    }

    private func makeContext(files: [String]) throws -> ScriptEngine {
        let context: ScriptEngine
        do {
            context = try ScriptEngines.make(name: "glasstube-solver")
        } catch {
            throw ChallengeError("\(error)")
        }
        let dir = Self.resourceDirectory
        for file in files {
            let code = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            do {
                try context.evaluate(code, sourceURL: "glasstube://nsigsolver/\(file)")
            } catch let exception as ScriptException {
                throw ChallengeError("error cargando \(file): \(exception)")
            }
        }
        return context
    }

    /// `JSON.stringify(entry(JSON.parse(input)))`: el JSON se pasa como valor, no como código.
    private func run(_ context: ScriptEngine, entry: String, input: [String: Any]) throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let text: String?
        do {
            text = try context.callJSON(entry: entry, input: json)
        } catch let exception as ScriptException {
            throw ChallengeError("\(context.name): \(exception)")
        }
        guard let text, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChallengeError("salida del solver ilegible")
        }
        return object
    }
}
