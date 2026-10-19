import AppKit
import Foundation

// AppKit con política .prohibited: sin icono en el Dock, pero con run loop principal para WKWebView (PoToken de
// `formats`), como el CLI de glasstube-spike.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    let code = await CLI(arguments: Array(CommandLine.arguments.dropFirst())).run()
    exit(code)
}
app.run()
