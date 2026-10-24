#if canImport(AppKit)
import AppKit
#endif
import Foundation

#if canImport(AppKit)
// AppKit con política .prohibited: sin icono en el Dock, pero con run loop principal para WKWebView (PoToken de
// `formats`), como el CLI de glasstube-spike.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    let code = await CLI(arguments: Array(CommandLine.arguments.dropFirst())).run()
    exit(code)
}
app.run()
#else
// Fuera de macOS basta la cola principal: el WebView2 del PoToken tiene su propio hilo y bucle de mensajes.
Task { @MainActor in
    let code = await CLI(arguments: Array(CommandLine.arguments.dropFirst())).run()
    exit(code)
}
dispatchMain()
#endif
