import Foundation

/// Identificadores de parte UMP (`ump_part_id.proto` / `UMPPartId.java` de SmartTube).
public enum UMPPartID: Int, Sendable {
    case onesieHeader = 10, onesieData = 11
    case mediaHeader = 20, media = 21, mediaEnd = 22
    case liveMetadata = 31
    case nextRequestPolicy = 35
    case formatInitializationMetadata = 42
    case sabrRedirect = 43, sabrError = 44, sabrSeek = 45
    case reloadPlayerResponse = 46
    case playbackStartPolicy = 47, allowedCachedFormats = 48
    case startBWSamplingHint = 49, pauseBWSamplingHint = 50
    case selectableFormats = 51, requestIdentifier = 52, requestCancellationPolicy = 53
    case timelineContext = 55, requestPipelining = 56
    case sabrContextUpdate = 57, streamProtectionStatus = 58, sabrContextSendingPolicy = 59
    case lawnmowerPolicy = 60, sabrAck = 61, endOfTrack = 62
    case prewarmConnection = 65, playbackDebugInfo = 66, snackbarMessage = 67

    public static func name(_ raw: Int) -> String {
        UMPPartID(rawValue: raw).map { "\($0)" } ?? "parte\(raw)"
    }
}

public struct UMPPart: Sendable {
    public let type: Int
    public let payload: Data
}

/// Decodificador UMP incremental (`UMPDecoder.java`): se le dan bytes conforme llegan y devuelve las partes
/// completas. Cada parte es `varint(tipo) varint(tamaño) payload`, con el varint propio de UMP: el número de
/// unos iniciales del primer byte da la longitud (1–5 bytes) y el resto va en little-endian.
/// https://github.com/gsuberland/UMP_Format/blob/main/UMP_Format.md
public struct UMPDecoder {
    private var buffer = Data()

    public init() {}

    public var pendingBytes: Int { buffer.count }

    public mutating func feed(_ chunk: Data) -> [UMPPart] {
        buffer.append(chunk)
        var parts: [UMPPart] = []
        var offset = buffer.startIndex
        while true {
            guard let (type, afterType) = Self.readVarint(buffer, at: offset),
                  let (size, afterSize) = Self.readVarint(buffer, at: afterType),
                  buffer.endIndex - afterSize >= Int(size) else { break }
            let end = afterSize + Int(size)
            parts.append(UMPPart(type: Int(type), payload: buffer.subdata(in: afterSize..<end)))
            offset = end
        }
        if offset > buffer.startIndex { buffer = buffer.subdata(in: offset..<buffer.endIndex) }
        return parts
    }

    /// Varint de UMP (no es el de protobuf). Devuelve nil si faltan bytes.
    public static func readVarint(_ data: Data, at index: Data.Index) -> (UInt64, Data.Index)? {
        guard index < data.endIndex else { return nil }
        let first = UInt64(data[index])
        let size = first < 0x80 ? 1 : first < 0xC0 ? 2 : first < 0xE0 ? 3 : first < 0xF0 ? 4 : 5
        guard data.endIndex - index >= size else { return nil }
        var shift: UInt64 = 0
        var value: UInt64 = 0
        if size < 5 {
            shift = UInt64(8 - size)
            value = first & ((1 << shift) - 1)
        }
        for i in 1..<size {
            value |= UInt64(data[index + i]) << shift
            shift += 8
        }
        return (value, index + size)
    }
}
