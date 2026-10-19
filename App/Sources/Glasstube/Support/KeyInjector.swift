import AppKit

/// Teclas reales dentro de la app (`NSEvent` por `NSApp.sendEvent`, el mismo camino que el teclado): llegan a
/// `onKeyPress` de la vista con foco. Las usan la automatización de pruebas (`-GTKeys`) y la cruceta del teléfono
/// (control remoto: flechas, Retorno y Esc).
enum KeyInjector {
    /// `space`, `return`, `tab`, `escape`, `left`, `right`, `up`, `down`, un carácter (`j`, `>`) o `cmd+<carácter>`
    /// (atajo de menú).
    static func press(_ key: String, in window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow else { return }
        let special: [String: (String, UInt16)] = [
            "space": (" ", 49), "return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1b}", 53),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
        ]
        var flags: NSEvent.ModifierFlags = []
        let characters: String
        let code: UInt16
        if key.hasPrefix("cmd+") {
            // Atajo de menú (p. ej. `cmd+,` abre Ajustes): va por el menú principal, como un equivalente de teclado.
            let character = String(key.dropFirst(4))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: character, charactersIgnoringModifiers: character,
                                            isARepeat: false, keyCode: 0) {
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
                if Automation.shared.logsKeys { NSLog("Glasstube automation: atajo \(key) → \(handled ? "atendido" : "sin atender")") }
            }
            return
        }
        if let (chars, keyCode) = special[key] {
            characters = chars
            code = keyCode
            if ["left", "right", "up", "down"].contains(key) { flags = [.function, .numericPad] }
        } else {
            characters = key
            code = 0
            if [">", "<"].contains(key) { flags = [.shift] }
        }
        let base = key == ">" ? "." : (key == "<" ? "," : characters)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: base, isARepeat: false, keyCode: code) else { continue }
            // Si la ventana todavía no es la principal (la app se acaba de activar), directo a ella.
            if window.isKeyWindow { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
    }
}
