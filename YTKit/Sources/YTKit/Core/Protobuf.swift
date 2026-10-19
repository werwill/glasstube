import Foundation

/// Protobuf mínimo (wire format) para los mensajes de SABR, sin swift-protobuf.
/// SmartTube compila los `.proto` de `exoplayer-amzn-2.10.6/library/sabr/src/main/proto/sabr/` con protobuf-lite;
/// aquí basta con escribir y leer campos por número.
public struct ProtoWriter {
    public private(set) var data = Data()

    public init() {}

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func tag(_ field: Int, _ wireType: UInt64) { varint(UInt64(field) << 3 | wireType) }

    /// int32/int64/uint/enum/bool. Los negativos se codifican como int64 (10 bytes), igual que protobuf.
    public mutating func int(_ field: Int, _ value: Int64?) {
        guard let value else { return }
        tag(field, 0)
        varint(UInt64(bitPattern: value))
    }

    public mutating func int(_ field: Int, _ value: Int?) { int(field, value.map(Int64.init)) }

    public mutating func uint(_ field: Int, _ value: UInt64?) {
        guard let value else { return }
        tag(field, 0)
        varint(value)
    }

    public mutating func bool(_ field: Int, _ value: Bool?) { int(field, value.map { $0 ? 1 : 0 } as Int?) }

    public mutating func float(_ field: Int, _ value: Float?) {
        guard let value else { return }
        tag(field, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func bytes(_ field: Int, _ value: Data?) {
        guard let value else { return }
        tag(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: Int, _ value: String?) { bytes(field, value.map { Data($0.utf8) }) }

    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

/// Lector de campos: agrupa por número; los mensajes anidados se vuelven a leer con `ProtoFields(data:)`.
public struct ProtoFields: CustomStringConvertible {
    public enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public private(set) var fields: [Int: [Value]] = [:]

    public init(_ data: Data) throws {
        var index = data.startIndex
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < data.endIndex, shift < 64 else { throw ProtoError("varint truncado") }
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }
        func readFixed(_ count: Int) throws -> UInt64 {
            guard data.endIndex - index >= count else { throw ProtoError("fixed\(count * 8) truncado") }
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(data[index + i]) << (8 * UInt64(i)) }
            index += count
            return value
        }
        while index < data.endIndex {
            let key = try readVarint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0: value = .varint(try readVarint())
            case 1: value = .fixed64(try readFixed(8))
            case 2:
                let length = Int(try readVarint())
                guard length >= 0, data.endIndex - index >= length else { throw ProtoError("campo \(field) truncado") }
                value = .bytes(data.subdata(in: index..<index + length))
                index += length
            case 5: value = .fixed32(UInt32(try readFixed(4)))
            default: throw ProtoError("wire type \(key & 7) no soportado (campo \(field))")
            }
            fields[field, default: []].append(value)
        }
    }

    public func int(_ field: Int) -> Int64? {
        guard case .varint(let v)? = fields[field]?.last else { return nil }
        return Int64(bitPattern: v)
    }

    public func uint(_ field: Int) -> UInt64? {
        guard case .varint(let v)? = fields[field]?.last else { return nil }
        return v
    }

    public func bool(_ field: Int) -> Bool? { uint(field).map { $0 != 0 } }

    public func bytes(_ field: Int) -> Data? {
        guard case .bytes(let d)? = fields[field]?.last else { return nil }
        return d
    }

    public func string(_ field: Int) -> String? { bytes(field).map { String(decoding: $0, as: UTF8.self) } }

    public func message(_ field: Int) throws -> ProtoFields? { try bytes(field).map(ProtoFields.init) }

    public func repeatedInts(_ field: Int) -> [Int64] {
        (fields[field] ?? []).flatMap { value -> [Int64] in
            switch value {
            case .varint(let v): return [Int64(bitPattern: v)]
            case .bytes(let packed): // repeated int32 empaquetado
                return (try? ProtoFields.packedVarints(packed)) ?? []
            default: return []
            }
        }
    }

    static func packedVarints(_ data: Data) throws -> [Int64] {
        var out: [Int64] = []
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                out.append(Int64(bitPattern: result))
                result = 0
                shift = 0
            } else {
                shift += 7
            }
        }
        return out
    }

    /// Volcado legible para depurar partes desconocidas.
    public var description: String {
        fields.keys.sorted().map { key in
            let values = fields[key]!.map { value -> String in
                switch value {
                case .varint(let v): return String(v)
                case .fixed64(let v): return "f64:\(v)"
                case .fixed32(let v): return "f32:\(v)"
                case .bytes(let d):
                    let text = String(decoding: d, as: UTF8.self)
                    let printable = d.count < 120 && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
                    return printable ? "\"\(text)\"" : "<\(d.count) B>"
                }
            }
            return "\(key)=\(values.joined(separator: ","))"
        }.joined(separator: " ")
    }
}

public struct ProtoError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    /// base64url (con o sin relleno), como `Base64.decode(…, Base64.URL_SAFE)` de Android.
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.replacingOccurrences(of: "%3D", with: "=").replacingOccurrences(of: "%3d", with: "=")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
