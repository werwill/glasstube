// swift-tools-version:6.0
import PackageDescription

// PlaybackKit, el motor de reproducción de Glasstube (fase 1). Ver NOTAS.md.
// - PlaybackKit: protocolo `PlayerEngine`, `MPVEngine` (libmpv propia, LGPL, enlazada de forma dinámica desde
//   Vendor/Libmpv.xcframework; salida Metal u OpenGL) y `AVEngine` (AVPlayer, directos HLS).
// - YouTubeSource: fuente SABR (`SabrMediaSource`) y manifiesto HLS de directos, sobre glasstube/YTKit (player, `n`,
//   PoToken y SABR/UMP salen de ahí; este módulo solo adapta `SabrSession` a `StreamedMediaSource`).
// - PlaybackDemo: ventana mínima que reproduce un videoId público con MPVEngine.
//
// Antes del primer `swift build`: Scripts/fetch-libmpv.sh && Scripts/link-libmpv.sh (crean Vendor/Libmpv.xcframework).
let package = Package(
    name: "PlaybackKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlaybackKit", targets: ["PlaybackKit"]),
        .library(name: "YouTubeSource", targets: ["YouTubeSource"]),
        .executable(name: "PlaybackDemo", targets: ["PlaybackDemo"]),
    ],
    dependencies: [
        .package(path: "../YTKit"),
    ],
    targets: [
        .binaryTarget(name: "Libmpv", path: "Vendor/Libmpv.xcframework"),
        .target(
            name: "PlaybackKit",
            dependencies: ["Libmpv"],
            swiftSettings: [.swiftLanguageMode(.v5)], // los avisos de OpenGL obsoleto son del respaldo y se quedan
            linkerSettings: [.linkedFramework("OpenGL"), .linkedFramework("QuartzCore"), .linkedFramework("AVFoundation"), .linkedFramework("AVKit")]
        ),
        .target(
            name: "YouTubeSource",
            dependencies: ["PlaybackKit", .product(name: "YTKit", package: "YTKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Lógica del motor que no necesita red ni ventana. Como en YTKit: con Command Line Tools hay que pasarle al
        // compilador el plugin de las macros de Swift Testing.
        .testTarget(
            name: "PlaybackKitTests",
            dependencies: ["PlaybackKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"]),
            ]
        ),
        .executableTarget(
            name: "PlaybackDemo",
            dependencies: ["PlaybackKit", "YouTubeSource"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
