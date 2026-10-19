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
    ],
    targets: [
        .executableTarget(
            name: "Glasstube",
            dependencies: [
                .product(name: "YTKit", package: "YTKit"),
                .product(name: "PlaybackKit", package: "PlaybackKit"),
                .product(name: "YouTubeSource", package: "PlaybackKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
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
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"]),
            ]
        ),
    ]
)
