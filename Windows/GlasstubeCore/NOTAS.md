# GlasstubeCore — notas (app de Windows, 24-oct-2026)

La lógica de la app de Windows sin interfaz, sobre YTKit. La interfaz WinUI 3 (otro paquete) solo dibuja y llama a
estos modelos.

```bash
swift build
swift test      # 38 pruebas en 8 suites
```

## De dónde sale

Son los modelos de `App/Sources/Glasstube` (la app de Mac), copiados sin AppKit ni SwiftUI. La app de Mac no cambió.
Hasta que la app de Mac use este paquete, un arreglo en uno de estos archivos hay que hacerlo en los dos lados.

| Aquí | En la app de Mac | Qué cambió |
|---|---|---|
| `Accounts/AccountModel.swift` | `App/AccountModel.swift` | Errores del Administrador de credenciales (`CredentialManagerError`); `-GTAnonimo` y `-GTSinCorreo` se leen en `CaptureMode`; `avatarURL(points:)` con `Double` |
| `Library/LocalLibrary.swift`, `ChannelGroups.swift`, `PlayQueue.swift` | `App/` | «esta PC»; `move(fromOffsets:toOffset:)` propio (el de SwiftUI no existe fuera de Apple) |
| `Player/PanelModels.swift` | `Player/PanelModels.swift` | Nada |
| `Navigation/Navigation.swift` | Principio de `App/AppModel.swift` | `PlayerPresentation` sin `.pip` (en Windows no hay PiP del sistema) |
| `Settings/AppSettings.swift` | `App/AppSettings.swift` | El tema se avisa con `onAppearanceChange`; `defaultRemoteName` con el nombre del equipo (`GetComputerNameExW`); sin el ajuste de Spotlight |
| `Services/SponsorBlock.swift` | `Services/SponsorBlock.swift` | Color en `RGBColor`; SHA-256 de swift-crypto |
| `Services/UpdateChecker.swift` | `Services/UpdateChecker.swift` | `download()` devuelve la URL y la interfaz la abre (`Launcher.LaunchUriAsync`); sin la vista del aviso |
| `Services/PlayerExtras.swift` | `Services/PlayerExtras.swift` | Sin el recorte con `NSImage` (la interfaz recorta la hoja con `frame(at:duration:)`) |
| `Services/Community.swift` | `Services/Community.swift` | Solo `DeArrowStore`, sin la vista `LateImage` |
| `Support/Format.swift` | `Support/Format.swift` | Sin `quality(_: MediaTrack)`, que es de PlaybackKit |

Todo lo que usa la interfaz es `public`. Las pruebas importan el paquete sin `@testable`, así que también comprueban que
la interfaz de otro paquete puede usar cada modelo.

## Qué falta

- **Verificado:** compila y pasan las 38 pruebas en Linux (Swift 6.2, imagen `swift:6.2-noble`).
- **No verificado:** compilar en Windows. Lo único propio de Windows aquí es `GetComputerNameExW` (WinSDK); lo demás es
  Foundation, que ya usa YTKit en Windows.
- Falta comprobar en la PC a qué carpeta de AppData apunta `applicationSupportDirectory` (ahí van `library.json` y
  `groups.json`) y dónde guarda Foundation los `UserDefaults` en Windows.
- Quedan en la app de Mac, para hacerse después: `PlayerModel` (estado del reproductor, atado a la ventana), `AppModel`,
  `RemoteControl` (control remoto desde el teléfono, que depende de los dos) e `ImagePipeline`.
