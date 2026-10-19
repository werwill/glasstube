import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import YTKit

/// Hoja «Vincular un teléfono» (`AddDevicePresenter` de SmartTube): el código de 12 dígitos grande para «Vincular con
/// código de TV» en la app de YouTube, el QR que abre lo mismo con la cámara y el estado hasta que el teléfono se
/// conecta. Hoja del sistema, como la de inicio de sesión.
struct PairingSheet: View {
    @Environment(RemoteControl.self) private var remote
    @ViewState private var copied = false

    var body: some View {
        VStack(spacing: 22) {
            header
            switch remote.pairing {
            case .requesting, .none:
                ProgressView("Pidiendo un código a YouTube…")
                    .frame(height: 200)
            case .code(let code):
                codeView(code)
            case .failed(let message):
                ContentUnavailableView {
                    Label("No se pudo pedir el código", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reintentar") { remote.requestCode() }
                        .buttonStyle(.glassProminent)
                }
                .frame(height: 200)
            }
            status
            footer
        }
        .padding(28)
        .frame(width: 600)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Vincular un teléfono").font(.title2.weight(.semibold))
            Text("Controla Glasstube desde la app de YouTube: elige videos, pausa, adelanta, cambia el volumen y los subtítulos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeView(_ code: LoungePairingCode) -> some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                Text("En la app de YouTube del teléfono, toca **Transmitir** › **Vincular con código de TV** y escribe:")
                    .fixedSize(horizontal: false, vertical: true)
                Text(code.formatted)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Código \(code.digits.map(String.init).joined(separator: " "))")
                HStack(spacing: 10) {
                    Button(copied ? "Copiado" : "Copiar código", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.digits, forType: .string)
                        copied = true
                    }
                    Button("Pedir otro código", systemImage: "arrow.clockwise") {
                        copied = false
                        remote.requestCode()
                    }
                }
                .buttonStyle(.glass)
            }
            VStack(spacing: 8) {
                QRCodeView(text: code.pairURL.absoluteString)
                    .frame(width: 132, height: 132)
                Text("O escanéalo con la cámara")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let paired = remote.pairedRemote {
            Label {
                Text("«\(remote.displayName(paired))» se conectó. Elige un video en el teléfono y tócalo: se verá aquí.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout.weight(.medium))
        } else if case .code = remote.pairing {
            HStack(spacing: 8) {
                switch remote.state {
                case .connected:
                    ProgressView().controlSize(.small)
                    Text("Esperando al teléfono… Aparecerá como «\(remote.settings.remoteName)».")
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Conectando con YouTube…")
                case .retrying(let after, let reason):
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    Text("Sin conexión con YouTube (\(reason)). Reintento en \(Int(after)) s.")
                case .stopped:
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("El control remoto está apagado.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Label {
                Text("El enlace vive mientras Glasstube está abierta. El teléfono queda vinculado: la próxima vez basta con tocar Transmitir. Para olvidar todos los teléfonos, ve a Ajustes › Control remoto.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if remote.pairedRemote != nil {
                    Button("Listo") { remote.closePairing() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Cerrar") { remote.closePairing() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// QR generado en la Mac (CoreImage) con lo mismo que el de la app de TV: `https://youtube.com/pair/<código>?qr=1`.
/// Sobre blanco, con su margen, para que la cámara lo lea también en modo oscuro.
struct QRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            }
        }
        .accessibilityLabel("Código QR para vincular")
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// Ajustes › Control remoto (`RemoteControlSettingsPresenter`): activar, vincular, desvincular todos, el nombre en el
/// teléfono y quién está conectado.
struct RemoteSettings: View {
    @Environment(RemoteControl.self) private var remote
    @Environment(AppSettings.self) private var settings
    @ViewState private var name = ""
    @ViewState private var confirmUnlink = false

    var body: some View {
        Form {
            Section {
                Toggle("Controlar Glasstube desde la app de YouTube del teléfono",
                       isOn: Binding(get: { settings.remoteEnabled }, set: { remote.setEnabled($0) }))
                LabeledContent("Estado") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
                TextField("Nombre en el teléfono", text: $name)
                    .onSubmit { remote.rename(name) }
            } footer: {
                Text("La Mac hace de «tele» para la app de YouTube (el protocolo Lounge, como la app de TV y SmartTube). El enlace vive mientras Glasstube está abierta.")
            }
            Section("Teléfonos conectados ahora") {
                if remote.remotes.isEmpty {
                    Text(settings.remoteEnabled ? "Ninguno. En el teléfono, toca Transmitir y elige «\(settings.remoteName)»." : "El control remoto está apagado.")
                        .foregroundStyle(.secondary)
                }
                ForEach(remote.remotes) { phone in
                    Label(remote.displayName(phone), systemImage: "iphone")
                }
            }
            Section {
                Button("Vincular un teléfono…") { pairFromSettings() }
                Button("Desvincular todos los teléfonos…", role: .destructive) { confirmUnlink = true }
                    .confirmationDialog("¿Desvincular todos los teléfonos?", isPresented: $confirmUnlink) {
                        Button("Desvincular todos", role: .destructive) { remote.unlinkAll() }
                    } message: {
                        Text("Glasstube cambia de identidad para YouTube: los teléfonos vinculados dejan de verla y hay que vincularlos otra vez con un código.")
                    }
            } footer: {
                Text("Desde el teléfono: elegir un video y la cola, reproducir y pausar, adelantar, siguiente y anterior, el volumen, los subtítulos y la cruceta (flechas, aceptar y atrás, como el teclado).")
            }
        }
        .formStyle(.grouped)
        .onAppear { name = settings.remoteName }
    }

    private var statusText: String {
        switch remote.state {
        case .stopped: "Apagado"
        case .connecting: "Conectando con YouTube…"
        case .connected: remote.remotes.isEmpty ? "Listo; ningún teléfono conectado" : "Conectado con \(remote.remotes.count == 1 ? "un teléfono" : "\(remote.remotes.count) teléfonos")"
        case .retrying(let after, _): "Sin conexión; reintento en \(Int(after)) s"
        }
    }

    private var statusColor: Color {
        switch remote.state {
        case .stopped: .secondary
        case .connecting: .yellow
        case .connected: .green
        case .retrying: .orange
        }
    }

    /// La hoja va en la ventana principal: Ajustes se cierra para que quede a la vista.
    private func pairFromSettings() {
        NSApp.keyWindow?.performClose(nil)
        remote.app.mainWindow?.makeKeyAndOrderFront(nil)
        remote.beginPairing()
    }
}
