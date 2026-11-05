// swift-tools-version:6.2
import PackageDescription

// Glasstube.app (fase 1, interfaz): la app SwiftUI de macOS que reimplementa SmartTube con Liquid Glass, sobre YTKit
// (catálogo y streams) y PlaybackKit (libmpv propia, SABR). Ver NOTAS.md.
//
// Sin Xcode: `swift build` compila el ejecutable y `Scripts/package-app.sh` arma Glasstube.app (Info.plist,
// Libmpv.framework en Contents/Frameworks con sus licencias, recursos de YTKit y la firma: el certificado propio
// «Glasstube Desarrollo» si existe, si no ad hoc).
let package = Package(
    name: "Glasstube",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../YTKit"),
        .package(path: "../PlaybackKit"),
        // Fase 5b: actualizaciones dentro de la app (MIT). Es un binario (Sparkle.xcframework) que SwiftPM baja de las
        // versiones de GitHub; trae también `bin/` con generate_keys, sign_update y generate_appcast.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Glasstube",
            dependencies: [
                .product(name: "YTKit", package: "YTKit"),
                .product(name: "PlaybackKit", package: "PlaybackKit"),
                .product(name: "YouTubeSource", package: "PlaybackKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                // Fase 6: el compilador deja aquí las claves localizables, con sus especificadores (`%lld`, `%@`). Las
                // leen Scripts/cadenas.py y la prueba de que todas tienen traducción. No necesita Xcode.
                .unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path", Context.packageDirectory + "/.build/cadenas"]),
            ],
            linkerSettings: [
                // Dentro de Glasstube.app, Libmpv.framework va en Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("MediaPlayer"),
            ]
        ),
        // Lógica de la app sin interfaz (cuentas, biblioteca). Como en YTKit: con Command Line Tools hay que pasarle al
        // compilador el plugin de las macros de Swift Testing.
        .testTarget(
            name: "GlasstubeTests",
            dependencies: ["Glasstube", .product(name: "YTKit", package: "YTKit")],
            // Fase 5b: un respaldo de SmartTube de prueba (Fixtures/smarttube-respaldo.zip).
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"]),
            ]
        ),
    ]
)
