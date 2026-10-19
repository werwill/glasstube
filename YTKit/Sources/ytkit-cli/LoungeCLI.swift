import Foundation
import YTKit

/// Fase 4: `ytkit lounge` (la pantalla de Lounge sin la app) y `ytkit link` (cómo se interpreta un enlace).
extension CLI {
    /// Pide un código, abre el canal y escribe lo que llega del teléfono durante N s. Responde `getNowPlaying` con
    /// «nada suena» y los cambios de volumen, para que el teléfono no se quede esperando. La identidad vive en memoria
    /// (cada corrida es una pantalla nueva) salvo con `--guardar`, que usa la misma clave que la app en
    /// `UserDefaults` de la CLI.
    func lounge(_ options: Options) async throws {
        let seconds = Double(options.int("--seconds") ?? 120)
        let name = options.value("--nombre") ?? "Glasstube (ytkit)"
        let store: LoungeIdentityStore = options.has("--guardar") ? UserDefaultsLoungeIdentityStore() : MemoryLoungeIdentityStore()
        let screen = LoungeScreen(name: name, store: store)
        let events = await screen.events()
        await screen.start()
        if !options.has("--sin-codigo") {
            let code = try await screen.pairingCode()
            print("Código para «Vincular con código de TV»: \(options.has("--mostrar") ? code.formatted : "\(code.formatted.prefix(3))-…-…-… (--mostrar para verlo)")")
        }
        print("Pantalla «\(name)» escuchando \(Int(seconds)) s…")
        let started = Date()
        let listener = Task {
            for await event in events {
                let at = String(format: "%5.1f s", Date().timeIntervalSince(started))
                switch event {
                case .state(let state): print("\(at)  estado: \(state)")
                case .remotes(let remotes): print("\(at)  conectados: \(remotes.map { "\($0.name) [\($0.app ?? "?")]" })")
                case .command(let command):
                    print("\(at)  ← \(Self.describe(command))")
                    switch command {
                    case .getNowPlaying: await screen.send([.nowPlaying(nil)])
                    case .getVolume, .remoteConnected: await screen.send([.volumeChanged(volume: 100, muted: false)])
                    case .setVolume(let volume, _): await screen.send([.volumeChanged(volume: volume ?? 100, muted: false)])
                    case .setPlaylist(let playlist):
                        // Como si se reprodujera: el teléfono muestra el video y sus controles.
                        if let videoId = playlist.currentVideoId {
                            await screen.send([.nowPlaying(LoungeNowPlaying(videoId: videoId, currentTime: playlist.currentTime ?? 0, duration: nil,
                                                                            state: .playing, listId: playlist.listId,
                                                                            currentIndex: playlist.currentIndex, ctt: playlist.ctt))])
                        }
                    default: break
                    }
                }
            }
        }
        try await Task.sleep(for: .seconds(seconds))
        listener.cancel()
        await screen.stop()
    }

    static func describe(_ command: LoungeCommand) -> String {
        switch command {
        case .setPlaylist(let list), .updatePlaylist(let list):
            return "\(command.name) video \(list.currentVideoId ?? "-") en \(list.currentTime.map { String(format: "%.0f s", $0) } ?? "-"), cola de \(list.videoIds.count), índice \(list.currentIndex.map(String.init) ?? "-")"
        case .seekTo(let time): return "seekTo \(time)"
        case .setVolume(let volume, let delta): return "setVolume \(volume.map(String.init) ?? "-") delta \(delta.map(String.init) ?? "-")"
        case .dpad(let key): return "dpadCommand \(key.rawValue)"
        case .setSubtitlesTrack(let subs): return "setSubtitlesTrack \(subs.languageCode ?? "apagados")"
        case .remoteConnected(let remote), .remoteDisconnected(let remote): return "\(command.name) \(remote.name) [\(remote.app ?? "?")]"
        case .loungeStatus(let devices): return "loungeStatus \(devices.count) dispositivos"
        default: return command.name
        }
    }

    /// `ytkit link <texto>`: lo que entiende la app de un enlace pegado.
    func link(_ options: Options) {
        let text = options.positional.joined(separator: " ")
        guard let link = YouTubeLink.parse(text) else {
            print("no es un enlace de YouTube")
            return
        }
        print("\(link)\n  web: \(link.webURL.absoluteString)\n  app: \(link.appURL.absoluteString)")
    }
}
