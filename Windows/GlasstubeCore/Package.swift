// swift-tools-version:6.2
import PackageDescription

// GlasstubeCore: la lógica de la app de Windows sin interfaz, sobre YTKit. Cuentas, biblioteca local (historial, Ver
// más tarde, bloqueos), grupos de canales y suscripciones sin cuenta, cola, comentarios y chat del panel lateral,
// navegación, ajustes, SponsorBlock, DeArrow, extras del /player y el aviso de versiones.
//
// Sale de App/Sources/Glasstube (la app de Mac, que no cambia): son los mismos modelos sin AppKit ni SwiftUI, públicos
// para que la interfaz WinUI 3 (otro paquete) los use. Compila en Windows y en Linux (las pruebas corren en los dos).
let package = Package(
    name: "GlasstubeCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GlasstubeCore", targets: ["GlasstubeCore"]),
    ],
    dependencies: [
        .package(path: "../../YTKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "GlasstubeCore",
            dependencies: [
                .product(name: "YTKit", package: "YTKit"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows, .linux])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "GlasstubeCoreTests",
            dependencies: ["GlasstubeCore", .product(name: "YTKit", package: "YTKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
