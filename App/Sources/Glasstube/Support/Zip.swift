import Compression
import Foundation

/// ZIP mínimo para el respaldo (fase 5b), sin dependencias: escribe entradas con DEFLATE y lee las de un ZIP corriente
/// (guardadas o con DEFLATE, con o sin descriptor de datos, como las que escribe `ZipOutputStream` de Java en el respaldo
/// de SmartTube). Todo en memoria: un respaldo pesa kilobytes. Sin ZIP64, cifrado ni varios discos. DEFLATE sale del
/// framework Compression: `COMPRESSION_ZLIB` es DEFLATE crudo (RFC 1951), el mismo de ZIP.
nonisolated enum ZipArchive {
    struct Entry: Equatable {
        var path: String
        var data: Data
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAZip
        case unsupported(String)
        case corrupt(String)

        var description: String {
            switch self {
            case .notAZip: "no es un archivo ZIP"
            case .unsupported(let what): "el ZIP usa algo que no se admite (\(what))"
            case .corrupt(let what): "el ZIP está dañado (\(what))"
            }
        }
    }

    /// Ningún archivo de un respaldo se acerca a esto; más es un ZIP raro o una bomba de compresión.
    static let maxEntrySize = 256 * 1024 * 1024

    // MARK: - Escribir

    /// Un ZIP con las entradas en ese orden (nombres en UTF-8). Cada una va con DEFLATE salvo que comprimida no ocupe menos.
    static func make(_ entries: [Entry], date: Date = Date()) -> Data {
        var out = Data()
        var central = Data()
        let (time, day) = dosDateTime(date)
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let deflated = deflate(entry.data)
            let method: UInt16 = deflated == nil ? 0 : 8
            let body = deflated ?? entry.data
            let offset = UInt32(out.count)

            out.append(le32: 0x0403_4b50)
            out.append(le16: 20)              // versión necesaria: 2.0
            out.append(le16: 0x0800)          // nombres en UTF-8
            out.append(le16: method)
            out.append(le16: time)
            out.append(le16: day)
            out.append(le32: crc)
            out.append(le32: UInt32(body.count))
            out.append(le32: UInt32(entry.data.count))
            out.append(le16: UInt16(name.count))
            out.append(le16: 0)
            out.append(name)
            out.append(body)

            central.append(le32: 0x0201_4b50)
            central.append(le16: 0x0314)      // hecho en Unix, 2.0 (para que los permisos del atributo externo cuenten)
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: method)
            central.append(le16: time)
            central.append(le16: day)
            central.append(le32: crc)
            central.append(le32: UInt32(body.count))
            central.append(le32: UInt32(entry.data.count))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)           // extra
            central.append(le16: 0)           // comentario
            central.append(le16: 0)           // disco
            central.append(le16: 0)           // atributos internos
            central.append(le32: UInt32(0o100644) << 16)
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    // MARK: - Leer

    /// Las entradas que son archivos (las carpetas se omiten), en el orden del directorio central.
    static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw Failure.notAZip }
        // El final del directorio central: 22 bytes y un comentario de hasta 64 KB.
        var end = -1
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if u32(bytes, index) == 0x0605_4b50 {
                end = index
                break
            }
            index -= 1
        }
        guard end >= 0 else { throw Failure.notAZip }
        let count = Int(u16(bytes, end + 10))
        let centralSize = Int(u32(bytes, end + 12))
        let centralOffset = Int(u32(bytes, end + 16))
        guard count != 0xFFFF, centralOffset != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64") }
        guard centralOffset + centralSize <= end else { throw Failure.corrupt("directorio central fuera del archivo") }

        var entries: [Entry] = []
        var cursor = centralOffset
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x0201_4b50 else {
                throw Failure.corrupt("entrada del directorio central")
            }
            let flags = u16(bytes, cursor + 8)
            let method = u16(bytes, cursor + 10)
            let crc = u32(bytes, cursor + 16)
            let compressedSize = Int(u32(bytes, cursor + 20))
            let size = Int(u32(bytes, cursor + 24))
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = Int(u32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw Failure.corrupt("nombre de una entrada") }
            let nameBytes = bytes[(cursor + 46)..<(cursor + 46 + nameLength)]
            // Sin la marca de UTF-8, los nombres son CP437; los de SmartTube y los de este archivo son ASCII.
            let path = String(decoding: nameBytes, as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            if path.hasSuffix("/") { continue }
            guard flags & 0x1 == 0 else { throw Failure.unsupported("cifrado") }
            guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64") }
            guard size <= maxEntrySize else { throw Failure.unsupported("una entrada de más de 256 MB") }
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4b50 else {
                throw Failure.corrupt("cabecera local de \(path)")
            }
            let start = localOffset + 30 + Int(u16(bytes, localOffset + 26)) + Int(u16(bytes, localOffset + 28))
            guard start + compressedSize <= bytes.count else { throw Failure.corrupt("datos de \(path)") }
            let body = Data(bytes[start..<(start + compressedSize)])
            let content: Data
            switch method {
            case 0: content = body
            case 8: content = try inflate(body, size: size, path: path)
            default: throw Failure.unsupported("compresión \(method) en \(path)")
            }
            guard content.count == size, crc32(content) == crc else { throw Failure.corrupt("CRC de \(path)") }
            entries.append(Entry(path: path, data: content))
        }
        return entries
    }

    // MARK: - DEFLATE

    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }

    private static func inflate(_ data: Data, size: Int, path: String) throws -> Data {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { throw Failure.corrupt("datos de \(path)") }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.corrupt("DEFLATE de \(path)") }
        return output
    }

    // MARK: - Ayudas

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// Hora y fecha de MS-DOS (hora local, de 2 en 2 segundos, desde 1980).
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

nonisolated private extension Data {
    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(le32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
