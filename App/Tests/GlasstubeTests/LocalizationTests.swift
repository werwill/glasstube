import Foundation
import Testing

/// Fase 6: ninguna clave de la interfaz se queda sin traducción. Las claves no se listan a mano: las da el compilador
/// (`-emit-localized-strings` en Package.swift deja un .stringsdata por archivo en .build/cadenas), así que un
/// `Text("Algo nuevo")` sin su inglés hace fallar esta prueba. Para arreglarlo: Scripts/cadenas.py revisar.
@Suite struct LocalizationTests {
    private static let package = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Emitted: Decodable {
        struct Entry: Decodable {
            struct Location: Decodable { let startingLine: Int }
            let key: String
            let location: Location
        }
        let source: String
        let tables: [String: [Entry]]
    }

    /// Clave → «archivo:línea», sin los .stringsdata de archivos que ya no existen.
    private static func emittedKeys() throws -> [String: String] {
        let folder = package.appending(path: ".build/cadenas")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var keys: [String: String] = [:]
        for file in files where file.pathExtension == "stringsdata" {
            let data = try JSONDecoder().decode(Emitted.self, from: Data(contentsOf: file))
            guard FileManager.default.fileExists(atPath: data.source) else { continue }
            for entry in data.tables.values.joined() {
                keys[entry.key] = "\(URL(filePath: data.source).lastPathComponent):\(entry.location.startingLine)"
            }
        }
        return keys
    }

    private static func lproj(_ language: String) -> URL {
        package.appending(path: "Localization/\(language).lproj")
    }

    /// Las claves de un archivo de .lproj; Foundation lee igual .strings y .stringsdict.
    private static func table(_ language: String, _ file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: lproj(language).appending(path: file))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }

    /// Los especificadores de una cadena, ordenados: el orden puede cambiar con `%1$@`, los tipos no.
    private static func specifiers(_ text: String) -> [String] {
        let plain = text.replacingOccurrences(of: "%%", with: "")
        return plain.matches(of: /%(?:\d+\$)?(lld|ld|lf|d|u|f|@|s)/).map { String($0.output.1) }.sorted()
    }

    @Test(arguments: ["en", "es"]) func everyKeyHasATranslation(language: String) throws {
        let keys = try Self.emittedKeys()
        #expect(keys.count > 500, "El compilador no dejó claves en .build/cadenas (¿falta -emit-localized-strings?)")
        let strings = try Self.table(language, "Localizable.strings")
        let plurals = try Self.table(language, "Localizable.stringsdict")
        let missing = keys.filter { strings[$0.key] == nil && plurals[$0.key] == nil }
        let listing = missing.map { "\($0.value): \($0.key)" }.sorted().joined(separator: "\n")
        #expect(missing.isEmpty, "Claves sin traducción en \(language).lproj (Scripts/cadenas.py revisar):\n\(listing)")
    }

    @Test func noTranslationIsLeftOver() throws {
        let keys = try Self.emittedKeys()
        let leftover = try Self.table("en", "Localizable.strings").keys.filter { keys[$0] == nil }
        #expect(leftover.isEmpty, "Traducciones de claves que ya no existen: \(leftover.sorted())")
    }

    /// Un `%@` de menos o de más en una traducción truena o enseña basura en ejecución.
    @Test(arguments: ["en", "es"]) func translationsKeepTheFormatSpecifiers(language: String) throws {
        let strings = try Self.table(language, "Localizable.strings")
        for case let (key, value as String) in strings {
            #expect(Self.specifiers(key) == Self.specifiers(value), "«\(key)» → «\(value)»")
        }
    }

    @Test func pluralsFollowTheCount() throws {
        let english = try #require(Bundle(url: Self.lproj("en")))
        let spanish = try #require(Bundle(url: Self.lproj("es")))
        func groups(_ bundle: Bundle, _ groups: Int, _ channels: Int) -> String {
            String(format: bundle.localizedString(forKey: "%lld grupos con %lld canales", value: nil, table: nil), groups, channels)
        }
        func chat(_ bundle: Bundle, _ count: Int) -> String {
            String(format: bundle.localizedString(forKey: "Chat en vivo · %lld mensajes", value: nil, table: nil), count)
        }
        #expect(groups(english, 1, 1) == "1 group with 1 channel")
        #expect(groups(english, 2, 12) == "2 groups with 12 channels")
        #expect(groups(spanish, 1, 3) == "1 grupo con 3 canales")
        #expect(groups(spanish, 3, 1) == "3 grupos con 1 canal")
        #expect(chat(english, 1) == "Live Chat · 1 message")
        #expect(chat(english, 40) == "Live Chat · 40 messages")
        #expect(chat(spanish, 1) == "Chat en vivo · 1 mensaje")
        #expect(chat(spanish, 40) == "Chat en vivo · 40 mensajes")
    }

    @Test(arguments: ["en", "es"]) func systemFacingTextsExist(language: String) throws {
        #expect(try Self.table(language, "InfoPlist.strings")["NSHumanReadableCopyright"] != nil)
        #expect(try Self.table(language, "ServicesMenu.strings")["Open in Glasstube"] != nil)
    }

    /// Si el Info.plist no declara los idiomas, macOS no elige el inglés aunque esté el .lproj.
    @Test func infoPlistDeclaresTheLanguages() throws {
        let script = try String(contentsOf: Self.package.appending(path: "Scripts/package-app.sh"), encoding: .utf8)
        #expect(script.contains("<key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>"))
        #expect(script.contains("<key>CFBundleDevelopmentRegion</key><string>en</string>"))
        #expect(script.contains("Localization/*.lproj"))
    }
}
