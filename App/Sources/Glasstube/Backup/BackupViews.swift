import SwiftUI
import UniformTypeIdentifiers
import YTKit

/// Ajustes › Respaldo (fase 5b; `BackupSettingsPresenter` de SmartTube sin Google Drive): exportar e importar el ZIP de
/// Glasstube (o el de SmartTube), la copia diaria en iCloud Drive y los archivos para PocketTube y NewPipe.
struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(LocalLibrary.self) private var library
    @Environment(ChannelGroupStore.self) private var groups
    @ViewState private var importingBackup = false
    @ViewState private var importingGroups = false
    @ViewState private var export: ExportRequest?
    @ViewState private var lastImport: String?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var backup = model.backup
        Form {
            Section {
                LabeledContent("Incluye") {
                    Text(includedText)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Importar…") { importingBackup = true }
                        Button("Exportar…") { exportBackup() }
                    }
                } label: {
                    Text("Archivo de respaldo")
                    Text(backup.lastMessage ?? "Un ZIP de Glasstube o un respaldo de SmartTube")
                }
            } header: {
                Text("Respaldo de Glasstube")
            } footer: {
                Text("Un ZIP con JSON legible: grupos de canales, suscripciones de esta Mac, canales bloqueados, historial con las posiciones, Ver más tarde, la cola y los ajustes. **Nunca lleva tu sesión de YouTube, tokens ni nada del Llavero**, ni la vinculación del teléfono. Importar también acepta el respaldo de SmartTube (Ajustes › Respaldo › Respaldo local): trae grupos, suscripciones, bloqueados e historial. Al restaurar se combina con lo que hay (los ajustes se reemplazan); nada se borra.")
            }

            Section {
                Toggle("Guardar un respaldo cada día en iCloud Drive", isOn: $settings.iCloudBackup)
                    .disabled(!backup.isICloudAvailable)
                LabeledContent {
                    HStack(spacing: 8) {
                        if backup.isWorking { ProgressView().controlSize(.small) }
                        Button("Mostrar en Finder") { backup.revealICloudFolder() }
                        Button("Guardar ahora") { backup.backupToICloud() }
                    }
                    .disabled(!backup.isICloudAvailable || backup.isWorking)
                } label: {
                    Text(iCloudStatus)
                }
            } header: {
                Text("iCloud Drive")
            } footer: {
                Text(backup.isICloudAvailable
                     ? "En iCloud Drive › Glasstube, uno por día; se guardan los últimos \(BackupService.iCloudKeep). La primera vez macOS pregunta si Glasstube puede usar iCloud Drive. Para restaurar en otra Mac, «Importar…» y elige uno de esa carpeta."
                     : "iCloud Drive no está activado en esta Mac (Ajustes del Sistema › Apple ID › iCloud › iCloud Drive). Puedes guardar el respaldo donde quieras con «Exportar…».")
            }

            Section {
                LabeledContent {
                    Button("Importar…") { importingGroups = true }
                } label: {
                    Text("Importar grupos de canales")
                    Text(lastImport ?? "Un archivo de PocketTube (.json), de GrayJay (subscription_groups) o de NewPipe (suscripciones .json)")
                }
                LabeledContent {
                    Button("Exportar…") { exportPocketTube() }
                        .disabled(groups.groups.isEmpty)
                } label: {
                    Text("Grupos para PocketTube")
                    Text(groups.groups.isEmpty ? "No hay grupos todavía" : "\(groups.groups.count) \(groups.groups.count == 1 ? "grupo" : "grupos"), en el formato de PocketTube")
                }
                LabeledContent {
                    Menu("Exportar…") {
                        Button("Solo las suscripciones de esta Mac") { exportNewPipe(includeGroups: false) }
                            .disabled(groups.subscriptions.isEmpty)
                        Button("Suscripciones y canales de los grupos") { exportNewPipe(includeGroups: true) }
                    }
                    .fixedSize()
                    .disabled(groups.subscriptions.isEmpty && groups.groups.allSatisfy(\.channels.isEmpty))
                } label: {
                    Text("Suscripciones para NewPipe")
                    Text("\(groups.subscriptions.count) \(groups.subscriptions.count == 1 ? "canal" : "canales") en esta Mac")
                }
            } header: {
                Text("Otras apps")
            } footer: {
                Text("Los mismos formatos que acepta SmartTube. De PocketTube y GrayJay llegan grupos (uno con el mismo nombre recibe los canales que le falten); de NewPipe, las suscripciones, que pasan a Suscripciones de esta Mac. Los archivos exportados los leen PocketTube, NewPipe, SmartTube y Glasstube.")
            }

            Section("Datos de esta Mac") {
                LabeledContent {
                    Button("Mostrar en Finder") { revealDataFolder() }
                } label: {
                    Text("Carpeta de datos")
                    Text("~/Library/Application Support/Glasstube (library.json y groups.json)")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { backup.open(url) }
        }
        // Un solo `fileImporter` por vista: el de grupos va en el fondo.
        .background {
            Color.clear.fileImporter(isPresented: $importingGroups, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result { lastImport = model.importGroups(from: url) }
            }
        }
        .fileExporter(isPresented: exportPresented, document: export?.document, contentType: export?.type ?? .zip,
                      defaultFilename: export?.name) { result in
            switch result {
            case .success(let url): backup.didExport(to: url, error: nil)
            case .failure(let error): backup.didExport(to: nil, error: error)
            }
            export = nil
        }
        .sheet(item: $backup.pending) { pending in
            BackupRestoreSheet(pending: pending)
        }
    }

    private var includedText: String {
        let watchLater = library.watchLater.count
        var parts = ["\(groups.groups.count) \(groups.groups.count == 1 ? "grupo" : "grupos")",
                     "\(groups.subscriptions.count) \(groups.subscriptions.count == 1 ? "suscripción" : "suscripciones")",
                     "\(library.blockedChannels.count) \(library.blockedChannels.count == 1 ? "bloqueado" : "bloqueados")",
                     "\(library.history.count) en el historial"]
        if watchLater > 0 { parts.append("\(watchLater) en Ver más tarde") }
        if !model.queue.isEmpty { parts.append("\(model.queue.items.count) en la cola") }
        parts.append("ajustes")
        return parts.joined(separator: " · ")
    }

    private var iCloudStatus: String {
        guard model.backup.isICloudAvailable else { return "iCloud Drive no disponible" }
        guard let date = model.backup.lastICloudBackup else { return "Todavía no hay respaldos en iCloud Drive" }
        return "Último respaldo: \(date.formatted(.relative(presentation: .named)))"
    }

    private var exportPresented: Binding<Bool> {
        Binding(get: { export != nil }, set: { if !$0 { export = nil } })
    }

    private func exportBackup() {
        do {
            export = ExportRequest(document: ExportDocument(data: try model.backup.makeArchive()), type: .zip,
                                   name: BackupArchive.fileName())
        } catch {
            model.backup.didExport(to: nil, error: error)
        }
    }

    private func exportPocketTube() {
        guard let data = model.backup.pocketTubeData() else { return }
        export = ExportRequest(document: ExportDocument(data: data), type: .json, name: "Glasstube-grupos-pockettube.json")
    }

    private func exportNewPipe(includeGroups: Bool) {
        guard let data = model.backup.newPipeData(includeGroups: includeGroups) else { return }
        export = ExportRequest(document: ExportDocument(data: data), type: .json, name: "Glasstube-suscripciones-newpipe.json")
    }

    private func revealDataFolder() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glasstube", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// Qué se exporta: un documento ya armado, su tipo y el nombre sugerido.
struct ExportRequest {
    var document: ExportDocument
    var type: UTType
    var name: String
}

/// Los bytes de un archivo para `fileExporter`.
nonisolated struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.zip, .json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// La hoja «Restaurar»: de dónde es el respaldo, qué trae (cada parte se puede dejar fuera) y lo que no se trae.
struct BackupRestoreSheet: View {
    let pending: BackupService.PendingBackup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected: Set<BackupSection>

    init(pending: BackupService.PendingBackup) {
        self.pending = pending
        _selected = ViewState(initialValue: Set(pending.file.contents.sections))
    }

    private var contents: BackupContents { pending.file.contents }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "archivebox")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restaurar «\(pending.name)»")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(sourceText)
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                Section {
                    ForEach(contents.sections) { section in
                        Toggle(isOn: binding(for: section)) {
                            Label {
                                Text(section.title)
                                Text(detail(for: section))
                            } icon: {
                                Image(systemName: section.symbol)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: CGFloat(contents.sections.count) * 53 + 28)
            .padding(.horizontal, -20)
            // Lo que no se trae va en un párrafo y no en otra sección: la hoja cabe en la ventana de Ajustes.
            Text((["Se combina con lo que hay en esta Mac: lo que falte se agrega y nada se borra; de un video que esté en los dos queda la posición más reciente."] + pending.file.notes).joined(separator: " "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) {
                    model.backup.pending = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Restaurar") {
                    model.backup.restorePending(sections: selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var sourceText: String {
        switch pending.file.source {
        case .glasstube(let app, let created):
            let date = created.map { " del \($0.formatted(date: .long, time: .shortened))" } ?? ""
            return "Respaldo de Glasstube\(app.map { " \($0)" } ?? "")\(date)"
        case .smartTube:
            return "Respaldo de SmartTube: lo que tiene equivalente en Glasstube"
        }
    }

    private func detail(for section: BackupSection) -> String {
        let count = contents.count(section)
        switch section {
        case .groups:
            let channels = Set(contents.groups.flatMap { $0.channels.map(\.id) }).count
            return "\(count) \(count == 1 ? "grupo" : "grupos") con \(channels) \(channels == 1 ? "canal" : "canales")"
        case .subscriptions: return "\(count) \(count == 1 ? "canal" : "canales")"
        case .blocked: return "\(count) \(count == 1 ? "canal" : "canales")"
        case .history:
            var parts = ["\(contents.history.count) \(contents.history.count == 1 ? "video" : "videos")"]
            if !contents.watchLater.isEmpty { parts.append("\(contents.watchLater.count) en Ver más tarde") }
            if !contents.hiddenVideos.isEmpty { parts.append("\(contents.hiddenVideos.count) ocultos") }
            return parts.joined(separator: " · ")
        case .queue: return "\(count) \(count == 1 ? "video" : "videos")"
        case .settings: return "\(count) \(count == 1 ? "ajuste" : "ajustes") (reemplazan los de esta Mac)"
        }
    }

    private func binding(for section: BackupSection) -> Binding<Bool> {
        Binding(get: { selected.contains(section) }, set: { on in
            if on { selected.insert(section) } else { selected.remove(section) }
        })
    }
}
