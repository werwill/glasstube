#if !canImport(JavaScriptCore)
import CQuickJS
import Foundation

/// `ScriptEngine` sobre QuickJS (quickjs-ng, vendorizado en CQuickJS) para Windows, donde no hay JavaScriptCore.
///
/// meriyah parsea el player entero (~2,5 MB) con recursión profunda, y QuickJS mide la pila contra el hilo donde se
/// llamó por última vez a `JS_UpdateStackTop`. Por eso cada evaluación corre en un hilo propio con pila grande (los
/// hilos del pool de Swift Concurrency tienen poca y el actor puede saltar de uno a otro) y actualiza la cima ahí.
final class QuickJSEngine: ScriptEngine {
    let name = "QuickJS"
    private static let threadStackSize = 64 << 20
    private let runtime: OpaquePointer
    private let context: OpaquePointer

    init() throws {
        guard let runtime = JS_NewRuntime() else { throw ScriptException(description: "no se pudo crear el runtime de QuickJS") }
        guard let context = JS_NewContext(runtime) else {
            JS_FreeRuntime(runtime)
            throw ScriptException(description: "no se pudo crear el contexto de QuickJS")
        }
        // Un margen de 4 MB bajo el tamaño del hilo para el código nativo entre comprobaciones.
        JS_SetMaxStackSize(runtime, Self.threadStackSize - (4 << 20))
        self.runtime = runtime
        self.context = context
    }

    deinit {
        JS_FreeContext(context)
        JS_FreeRuntime(runtime)
    }

    func evaluate(_ code: String, sourceURL: String) throws {
        try onLargeStack {
            let value = try eval(code, filename: sourceURL)
            JS_FreeValue(context, value)
        }
    }

    func callJSON(entry: String, input: String) throws -> String? {
        try onLargeStack {
            let global = JS_GetGlobalObject(context)
            defer { JS_FreeValue(context, global) }
            let key = "__glasstubeInput"
            let inputValue = input.withCString { JS_NewStringLen(context, $0, strlen($0)) }
            _ = JS_SetPropertyStr(context, global, key, inputValue) // se queda con inputValue
            defer { _ = JS_SetPropertyStr(context, global, key, JS_NewStringLen(context, "", 0)) }
            let value = try eval("JSON.stringify(\(entry)(JSON.parse(\(key))))", filename: "glasstube://call")
            defer { JS_FreeValue(context, value) }
            return string(value)
        }
    }

    // MARK: - Interno

    private func eval(_ code: String, filename: String) throws -> JSValue {
        let value = code.withCString { JS_Eval(context, $0, strlen($0), filename, 0 /* JS_EVAL_TYPE_GLOBAL */) }
        // Como JavaScriptCore, que drena las microtareas al volver de evaluateScript.
        var pending: OpaquePointer?
        while JS_ExecutePendingJob(runtime, &pending) > 0 {}
        if JS_IsException(value) { throw ScriptException(description: pendingException()) }
        return value
    }

    private func pendingException() -> String {
        let exception = JS_GetException(context)
        defer { JS_FreeValue(context, exception) }
        let message = string(exception) ?? "excepción"
        let stackValue = JS_GetPropertyStr(context, exception, "stack")
        defer { JS_FreeValue(context, stackValue) }
        let stack = JS_IsUndefined(stackValue) ? "" : string(stackValue) ?? ""
        return "\(message)\n\(stack.prefix(600))"
    }

    private func string(_ value: JSValue) -> String? {
        var length = 0
        guard let pointer = JS_ToCStringLen(context, &length, value) else { return nil }
        defer { JS_FreeCString(context, pointer) }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    /// Corre `work` en un hilo con `threadStackSize` de pila y espera a que termine. El motor ya es síncrono (como
    /// `evaluateScript`), así que bloquear el hilo del actor no cambia nada para quien llama.
    private func onLargeStack<T>(_ work: () throws -> T) throws -> T {
        try withoutActuallyEscaping(work) { work in
            // El hilo vive un poco más que la espera: suelta el cierre antes de avisar, o no escaparía de verdad.
            let runtime = runtime
            let job = Job {
                JS_UpdateStackTop(runtime)
                return try work()
            }
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                job.run()
                done.signal()
            }
            thread.stackSize = Self.threadStackSize
            thread.start()
            done.wait()
            return try job.result!.get()
        }
    }

    private final class Job<T>: @unchecked Sendable {
        private var work: (() throws -> T)?
        var result: Result<T, Error>?
        init(_ work: @escaping () throws -> T) { self.work = work }
        func run() {
            result = Result { try work!() }
            work = nil
        }
    }
}
#endif
