import Foundation

// Utilidades de decodificación tolerante para las respuestas de Innertube.
//
// YouTube cambia los "renderers" sin aviso: aparecen campos nuevos, desaparecen otros y a veces un mismo campo cambia
// de tipo (un texto que pasa de `{"simpleText": …}` a cadena, un número que llega como cadena). Para que un cambio así
// no tire una fila entera, todos los campos de los modelos van envueltos en `@Lenient`: si el campo falta o no tiene la
// forma esperada, queda en nil y el resto se decodifica igual.

/// Clave dinámica para recorrer objetos JSON cuyo nombre de clave no se conoce de antemano (el nombre del renderer).
struct AnyKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Campo que nunca hace fallar la decodificación del objeto que lo contiene: ausente o con otra forma → nil.
@propertyWrapper
struct Lenient<T: Decodable & Sendable>: Decodable, Sendable {
    var wrappedValue: T?

    init() { wrappedValue = nil }
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// La conformidad sintetizada de `Decodable` llama a `decode(_:forKey:)` para las propiedades envueltas; aquí la
    /// clave ausente también da nil en lugar de `keyNotFound`.
    func decode<T>(_ type: Lenient<T>.Type, forKey key: Key) throws -> Lenient<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lenient(wrappedValue: nil)
    }
}

/// Entero que acepta número, número con decimales o cadena ("1080", "15414335").
struct FlexibleInt: Decodable, Sendable, Hashable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int(double)
        } else if let string = try? container.decode(String.self), let int = Int(string.trimmingCharacters(in: .whitespaces)) {
            value = int
        } else {
            throw DecodingError.typeMismatch(Int.self, .init(codingPath: decoder.codingPath, debugDescription: "no es un entero"))
        }
    }
}

/// Indirección para estructuras recursivas (un comando que contiene otro comando).
final class Box<T: Decodable & Sendable>: Decodable, @unchecked Sendable {
    let value: T
    init(from decoder: Decoder) throws { value = try T(from: decoder) }
}

/// Decodifica y recorre respuestas de Innertube en un hilo propio con pila de 16 MB.
///
/// Los árboles de renderers llegan a decenas de niveles y cada nivel son varios marcos de `Decodable` (más en compilación
/// de depuración). En la pila de 512 KB de los hilos secundarios (el pool de Swift Concurrency, los de Swift Testing) eso
/// desborda y el proceso muere con SIGBUS. El hilo dedicado evita depender de dónde se llame.
enum InnertubeDecoding {
    static let stackSize = 16 << 20

    /// Ejecuta `work` (decodificar y convertir) en el hilo de pila grande.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try work() }) }
            thread.stackSize = stackSize
            thread.name = "YTKit.decode"
            thread.start()
        }
    }

    /// Versión síncrona (pruebas, herramientas): bloquea el hilo actual hasta que termina.
    static func runSync<T>(_ work: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = Result { try work() }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return try box.result!.get()
    }

    static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await run { try JSONDecoder().decode(T.self, from: data) }
    }

    private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
}
