// swift-tools-version:6.0
import PackageDescription

// YTKit de Glasstube (fase 1): red y catálogo de YouTube, sin interfaz.
// - Streams: perfiles de cliente, Innertube /player, rotación de clientes, firma y `n` en JavaScriptCore, PoToken en
//   WKWebView (portado de glasstube-spike).
// - Sabr: cliente SABR/UMP, solo red y parseo (el búfer y los flujos de mpv van en PlaybackKit).
// - Catalog: Inicio, Explorar, búsqueda con sugerencias, canal y `next`, con paginación por `continuation`.
// ytkit = CLI de verificación (`home`, `search`, `channel`, `next`, …).
let package = Package(
    name: "YTKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "YTKit", targets: ["YTKit"]),
        .executable(name: "ytkit", targets: ["ytkit-cli"]),
    ],
    targets: [
        .target(
            name: "YTKit",
            resources: [
                .copy("Resources/clients.json"),
                .copy("Resources/nsigsolver"),
                .copy("Resources/potoken"),
            ],
            // El código portado de la fase 0 (Sabr, PoToken, solver) está escrito para el modo Swift 5.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "ytkit-cli", dependencies: ["YTKit"]),
        .testTarget(
            name: "YTKitTests",
            dependencies: ["YTKit"],
            resources: [.copy("Fixtures")],
            // Solo con Command Line Tools (sin Xcode), el build de SwiftPM no le pasa al compilador el plugin de las
            // macros de Swift Testing (@Test, #expect). Con Xcode instalado esta ruta no existe y no estorba.
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ]
)
