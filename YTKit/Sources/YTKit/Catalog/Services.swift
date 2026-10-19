import Foundation

// Contrato del servicio, en Swift y con async/await. Refleja `MediaServiceCore/mediaserviceinterfaces` de SmartTube
// (`ContentService.java`, `MediaItemService.java`): la app habla con estos protocolos y no con Innertube, igual que la
// interfaz de SmartTube solo conoce `ServiceManager`. Las variantes RxJava (`…Observe`) sobran con async/await.
//
// Los métodos que necesitan cuenta (suscripciones, historial, me gusta…) van con la sesión de `SignInService`; sin sesión
// lanzan `YTKitError.signInRequired`.

/// Catálogo: filas, búsqueda y canales (`ContentService`).
public protocol ContentService: Sendable {
    /// Inicio (`getHome`). Sin cuenta, YouTube ya no da recomendaciones; ver `BrowsePage.isFallback`.
    func home() async throws -> BrowsePage
    /// Tendencias (`getTrending`). YouTube retiró `FEtrending`; ver `BrowsePage.isFallback`.
    func trending() async throws -> BrowsePage
    /// Un destino de Explorar (`getMusic`, `getGaming`, `getNews`, `getSports`, `getLive`, `getMovies`).
    func topic(_ topic: Topic) async throws -> BrowsePage
    /// Resultados de búsqueda (`getSearch`). `params` es el filtro protobuf de YouTube (`sp`), si se quiere uno.
    func search(_ query: String, params: String?) async throws -> BrowsePage
    /// Sugerencias mientras se escribe (`getSearchTags`).
    func searchSuggestions(_ query: String) async throws -> [String]
    /// Canal en una pestaña (`getChannel`, `getChannelAsGrid`). `channelId` acepta UC…, @handle o URL.
    func channel(_ channelId: String, tab: ChannelTab.Kind) async throws -> ChannelPage
    /// Videos de una lista o mix (`getGroup(mediaItem)` para listas). `playlistId` sin el prefijo `VL`.
    func playlist(_ playlistId: String) async throws -> BrowsePage
    /// Más elementos de una fila (`continueGroup`).
    func continueGroup(_ group: MediaGroup) async throws -> MediaGroup
    /// Más filas de una página (`getGroup(reloadPageKey)` / continuación de `sectionList`).
    func continuePage(_ continuation: Continuation) async throws -> BrowsePage

    // Con cuenta (fase 2; sin sesión lanzan `YTKitError.signInRequired`).
    func subscriptions() async throws -> BrowsePage
    func history() async throws -> BrowsePage
    func playlists() async throws -> BrowsePage
}

/// Sesión de YouTube (`SignInService` de SmartTube: `signInObserve`, `getAccounts`, `selectAccount`, `removeAccount`,
/// `addOnAccountChange`). La implementa `AccountManager`.
public protocol SignInService: Sendable {
    /// Pide un código para youtube.com/activate (`signInObserve`, primera mitad).
    func beginSignIn() async throws -> DeviceCode
    /// Espera la autorización, guarda la sesión y trae sus cuentas (segunda mitad).
    func completeSignIn(_ code: DeviceCode) async throws -> AccountSnapshot
    /// Cuentas guardadas y la elegida (`getAccounts`, `getSelectedAccount`, `isSigned`).
    func load() async throws -> AccountSnapshot
    func select(accountId: String) async throws -> AccountSnapshot
    /// Cierra y revoca la sesión de Google de la cuenta (`removeAccount`).
    func signOut(accountId: String, revoke: Bool) async throws -> AccountSnapshot
    /// Cambios de cuenta (`addOnAccountChange`).
    func updates() -> AsyncStream<AccountSnapshot>
}

extension ContentService {
    public func search(_ query: String) async throws -> BrowsePage { try await search(query, params: nil) }
    public func channel(_ channelId: String) async throws -> ChannelPage { try await channel(channelId, tab: .home) }
}

/// Un video concreto: metadatos de reproducción y streams (`MediaItemService`).
public protocol MediaItemService: Sendable {
    /// Página de reproducción (`getMetadata`): metadatos, capítulos y sugeridos.
    func metadata(videoId: String, playlistId: String?, playlistIndex: Int?, params: String?) async throws -> MediaItemMetadata
    /// Streams con la rotación de clientes (`getFormatInfo`).
    func formatInfo(videoId: String, options: ResolveOptions) async -> ResolveReport

    // Con cuenta (fase 2; sin sesión lanzan `YTKitError.signInRequired`).
    func setLike(videoId: String) async throws
    func removeLike(videoId: String) async throws
    func setDislike(videoId: String) async throws
    func removeDislike(videoId: String) async throws
    func subscribe(channelId: String) async throws
    func unsubscribe(channelId: String) async throws
    func updateHistoryPosition(videoId: String, positionSeconds: Double) async throws
    func markAsNotInterested(feedbackToken: String) async throws
    /// Listas de la cuenta y si el video está en cada una (`getPlaylistsInfo`).
    func playlistsInfo(videoId: String) async throws -> [PlaylistInfo]
    func addToPlaylist(playlistId: String, videoId: String) async throws
    func removeFromPlaylist(playlistId: String, videoId: String) async throws
}

extension MediaItemService {
    public func metadata(videoId: String) async throws -> MediaItemMetadata {
        try await metadata(videoId: videoId, playlistId: nil, playlistIndex: nil, params: nil)
    }

    public func metadata(for item: MediaItem) async throws -> MediaItemMetadata {
        guard let videoId = item.videoId else { throw YTKitError.notAvailable("\(item.title) no es un video") }
        return try await metadata(videoId: videoId, playlistId: item.playlistId, playlistIndex: item.playlistIndex, params: item.params)
    }
}
