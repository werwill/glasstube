import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Motor de JavaScript síncrono donde corre el solver de firma y `n`: JavaScriptCore en macOS, QuickJS fuera de Apple
/// (`QuickJSEngine`). Un motor no es seguro entre hilos; `ChallengeSolver` lo usa siempre desde su actor.
protocol ScriptEngine: AnyObject {
    /// Nombre para los mensajes de error ("JavaScriptCore", "QuickJS").
    var name: String { get }
    /// Evalúa un script global; lanza `ScriptException` con mensaje y pila si el script lanza.
    func evaluate(_ code: String, sourceURL: String) throws
    /// `JSON.stringify(entry(JSON.parse(input)))`: el JSON se pasa como valor, no como código.
    func callJSON(entry: String, input: String) throws -> String?
}

struct ScriptException: Error, CustomStringConvertible {
    let description: String
}

enum ScriptEngines {
    /// El motor de esta plataforma.
    static func make(name: String) throws -> ScriptEngine {
        #if canImport(JavaScriptCore)
        try JavaScriptCoreEngine(name: name)
        #else
        try QuickJSEngine()
        #endif
    }
}

#if canImport(JavaScriptCore)
/// `JSContext` con un manejador de excepciones que guarda la última, invocado de forma síncrona dentro de
/// `evaluateScript`, en el hilo de quien llama.
final class JavaScriptCoreEngine: ScriptEngine {
    let name = "JavaScriptCore"
    private let context: JSContext
    private var lastException: String?

    init(name: String) throws {
        guard let context = JSContext() else { throw ScriptException(description: "no se pudo crear JSContext") }
        context.name = name
        self.context = context
        context.exceptionHandler = { [unowned self] _, exception in
            let message = exception?.toString() ?? "excepción"
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
            lastException = "\(message)\n\(stack.prefix(600))"
        }
    }

    func evaluate(_ code: String, sourceURL: String) throws {
        lastException = nil
        context.evaluateScript(code, withSourceURL: URL(string: sourceURL))
        if let lastException { throw ScriptException(description: lastException) }
    }

    func callJSON(entry: String, input: String) throws -> String? {
        context.setObject(input, forKeyedSubscript: "__glasstubeInput" as NSString)
        lastException = nil
        let value = context.evaluateScript("JSON.stringify(\(entry)(JSON.parse(__glasstubeInput)))")
        context.setObject(nil, forKeyedSubscript: "__glasstubeInput" as NSString)
        if let lastException { throw ScriptException(description: lastException) }
        return value?.toString()
    }
}
#endif
