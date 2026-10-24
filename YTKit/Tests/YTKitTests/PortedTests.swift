import Foundation
import Testing
@testable import YTKit

/// Lo portado de glasstube-spike que se puede probar sin red: perfiles de cliente, protobuf y UMP.
@Suite struct PortedTests {
    @Test func rotationStartsWithTheClientsThatWork() throws {
        let catalog = try ClientCatalog.load()
        // RESULTADOS.md, recomendación 1: TV_DOWNGRADED primero, VISIONOS segundo.
        #expect(catalog.defaultStart == "TV_DOWNGRADED")
        #expect(catalog.rotation(startingAt: catalog.defaultStart).prefix(2).map(\.id) == ["TV_DOWNGRADED", "VISIONOS"])
        #expect(catalog.rotation(startingAt: "WEB").first?.id == "WEB")
        #expect(catalog.rotation(startingAt: nil).count == catalog.rotation.count)
        #expect(catalog.profile("TV")?.clientName == "TVHTML5")
        #expect(catalog.profile("web")?.clientNameId == "1")
        #expect(catalog.profile("TV")?.browser?.name == "Cobalt")
    }

    @Test func catalogRequestBody() throws {
        let api = CatalogAPI(catalog: try ClientCatalog.load(), locale: CatalogLocale(language: "es-419", region: "MX"))
        let tv = try api.body(surface: .tv, visitorData: "VD", extra: ["browseId": "FEtopics_music"])
        let client = try #require((tv["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(client["clientName"] as? String == "TVHTML5")
        #expect(client["hl"] as? String == "es-419")
        #expect(client["gl"] as? String == "MX")
        #expect(client["visitorData"] as? String == "VD")
        #expect((client["tvAppInfo"] as? [String: Any])?["appQuality"] as? String == "TV_APP_QUALITY_FULL_ANIMATION")
        #expect(tv["browseId"] as? String == "FEtopics_music")
        let web = try api.body(surface: .web, visitorData: nil, extra: ["query": "x"])
        let webClient = try #require((web["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(webClient["clientName"] as? String == "WEB")
        #expect(webClient["tvAppInfo"] == nil)
    }

    @Test func protobufRoundTrip() throws {
        var writer = ProtoWriter()
        writer.int(1, 251)
        writer.uint(2, 1_700_000_000_000_000)
        writer.string(3, "xtags")
        writer.message(4) { $0.int(1, 7) }
        let fields = try ProtoFields(writer.data)
        #expect(fields.int(1) == 251)
        #expect(fields.uint(2) == 1_700_000_000_000_000)
        #expect(fields.string(3) == "xtags")
        #expect(try fields.message(4)?.int(1) == 7)
    }

    @Test func umpDecoderIsIncremental() throws {
        // Parte 21 (MEDIA) con 3 bytes y parte 58 (STREAM_PROTECTION_STATUS) con 1, entregadas a trozos.
        let bytes: [UInt8] = [21, 3, 0xAA, 0xBB, 0xCC, 58, 1, 0x08]
        var decoder = UMPDecoder()
        #expect(decoder.feed(Data(bytes[0..<3])).isEmpty)
        let first = decoder.feed(Data(bytes[3..<6]))
        #expect(first.map(\.type) == [21])
        #expect(first.first?.payload == Data([0xAA, 0xBB, 0xCC]))
        let second = decoder.feed(Data(bytes[6...]))
        #expect(second.map(\.type) == [58])
        #expect(decoder.pendingBytes == 0)
        // Varint de UMP de dos bytes: 0x80 | bajos 6 bits, luego el byte alto.
        // Sin opcional: `#expect` con `Optional<UInt64> == literal` tumba a swiftc 6.4.1 en Windows (SILGen).
        let varint = try #require(UMPDecoder.readVarint(Data([0x81, 0x02]), at: 0)).0
        #expect(varint == 1 + 2 << 6)
    }
}
