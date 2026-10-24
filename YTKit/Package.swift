// swift-tools-version:6.0
import PackageDescription

// YTKit de Glasstube (fase 1): red y catálogo de YouTube, sin interfaz.
// - Streams: perfiles de cliente, Innertube /player, rotación de clientes, firma y `n` en JavaScriptCore, PoToken en
//   WKWebView (portado de glasstube-spike).
// - Sabr: cliente SABR/UMP, solo red y parseo (el búfer y los flujos de mpv van en PlaybackKit).
// - Catalog: Inicio, Explorar, búsqueda con sugerencias, canal y `next`, con paginación por `continuation`.
// ytkit = CLI de verificación (`home`, `search`, `channel`, `next`, …).
//
// Fuera de Apple (Windows) cambian cuatro piezas, cada una detrás de un protocolo: el solver corre en QuickJS (CQuickJS,
// quickjs-ng vendorizado) en lugar de JavaScriptCore, el PoToken en WebView2 en lugar de WKWebView, la bóveda de
// cuentas en el Administrador de credenciales en lugar del Llavero, y SHA-256 sale de swift-crypto en lugar de CryptoKit.
// En macOS esas dependencias no se compilan (si se compila este paquete solo, CQuickJS y CWebView2 se compilan pero no
// se enlazan).
let nonApple: [Platform] = [.windows, .linux]

let package = Package(
    name: "YTKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "YTKit", targets: ["YTKit"]),
        .executable(name: "ytkit", targets: ["ytkit-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "CQuickJS",
            exclude: ["LICENSE"],
            cSettings: [
                .define("_GNU_SOURCE"),
                .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows])),
                .define("_WIN32_WINNT", to: "0x0601", .when(platforms: [.windows])),
            ],
            linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
        ),
        // Puente en C a WebView2 (COM) con el WebView2.h del paquete NuGet Microsoft.Web.WebView2. Fuera de Windows
        // compila vacío.
        .target(
            name: "CWebView2",
            exclude: ["LICENSE-WebView2.txt"],
            linkerSettings: [
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("shlwapi", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("uuid", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "YTKit",
            dependencies: [
                .target(name: "CQuickJS", condition: .when(platforms: nonApple)),
                .target(name: "CWebView2", condition: .when(platforms: [.windows])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
            ],
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
