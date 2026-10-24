// swift-tools-version:6.2
import PackageDescription

// GlasstubeFFI: YTKit y GlasstubeCore detrás de una API en C (GlasstubeFFI.dll) para la interfaz WinUI 3 en C#.
// La API es pequeña a propósito: funciones @_cdecl con cadenas JSON UTF-8 de ida y vuelta, y callbacks para lo
// asíncrono. La cabecera para C está en include/GlasstubeFFI.h (la usan el P/Invoke de la app y cualquier otro cliente).
//
// Todo lo de YTKit vive en el actor principal, que fuera de Apple es la cola principal de libdispatch. En la app nadie
// corre `dispatchMain()`: la interfaz llama a `gt_pump()` desde su hilo (el principal del proceso) para vaciarla, y
// así los callbacks llegan siempre en el hilo de la interfaz.
let package = Package(
    name: "GlasstubeFFI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GlasstubeFFI", type: .dynamic, targets: ["GlasstubeFFI"]),
    ],
    dependencies: [
        .package(path: "../../YTKit"),
        .package(path: "../GlasstubeCore"),
    ],
    targets: [
        // Acceso a la cola principal de libdispatch (`_dispatch_main_queue_callback_4CF`, la que vacía CFRunLoop).
        .target(name: "CDispatchPump"),
        .target(
            name: "GlasstubeFFI",
            dependencies: [
                "CDispatchPump",
                .product(name: "YTKit", package: "YTKit"),
                .product(name: "GlasstubeCore", package: "GlasstubeCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
