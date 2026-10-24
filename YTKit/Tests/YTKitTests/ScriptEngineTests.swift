import Foundation
import Testing
@testable import YTKit

/// El motor del solver: JavaScriptCore en macOS, QuickJS en Windows (y en Linux, donde corren estas pruebas en CI).
@Suite struct ScriptEngineTests {
    @Test func evaluatesAndPassesJSONAsValue() throws {
        let engine = try ScriptEngines.make(name: "prueba")
        try engine.evaluate("function echo(input) { return { type: 'ok', n: input.n * 2, text: input.text + '✓' } }",
                            sourceURL: "glasstube://prueba.js")
        let output = try #require(try engine.callJSON(entry: "echo", input: #"{"n":21,"text":"ñ\"'"}"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["n"] as? Int == 42)
        #expect(object["text"] as? String == "ñ\"'✓")
    }

    @Test func reportsExceptionsWithMessage() throws {
        let engine = try ScriptEngines.make(name: "prueba")
        #expect(throws: ScriptException.self) { try engine.evaluate("throw new Error('rota')", sourceURL: "glasstube://x.js") }
        do {
            _ = try engine.callJSON(entry: "noExiste", input: "{}")
            Issue.record("debía lanzar")
        } catch let error as ScriptException {
            #expect(error.description.contains("noExiste"))
        }
        // El motor sigue sirviendo después de una excepción.
        try engine.evaluate("var vivo = function () { return 1 }", sourceURL: "glasstube://y.js")
        #expect(try engine.callJSON(entry: "vivo", input: "null") == "1")
    }

    /// meriyah es recursivo: el player real anida mucho y en QuickJS eso necesita la pila grande de su hilo.
    @Test func meriyahParsesDeeplyNestedCode() throws {
        let engine = try ScriptEngines.make(name: "prueba")
        let dir = ChallengeSolver.resourceDirectory
        for file in ["polyfill.js", "meriyah-6.1.4.min.js"] {
            try engine.evaluate(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
                                sourceURL: "glasstube://nsigsolver/\(file)")
        }
        try engine.evaluate("function parse(input) { return meriyah.parse(input.code).body.length }", sourceURL: "glasstube://p.js")
        let depth = 1500
        let code = "var a = " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + ";"
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["code": code]), as: UTF8.self)
        #expect(try engine.callJSON(entry: "parse", input: input) == "1")
    }

    @Test func solverScriptsLoad() async throws {
        try await ChallengeSolver().warmUp()
    }
}
