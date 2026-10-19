import Foundation

/// Una cuenta de YouTube con la que se puede navegar: la personal o una de marca (`YouTubeAccount` de SmartTube).
/// Varias cuentas comparten una sesión de Google (`credentialId`); las de marca se eligen con `X-Goog-Pageid`.
/// No contiene tokens.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    /// `<sesión>/<pageId>` o `<sesión>/principal`.
    public var id: String
    /// Sesión de Google (refresh token) a la que pertenece.
    public var credentialId: String
    public var name: String
    /// Segunda línea de YouTube: el correo en la cuenta personal, el @identificador o "N suscriptores" en las de marca.
    public var byline: String?
    public var handle: String?
    public var avatar: [Thumbnail] = []
    /// `X-Goog-Pageid` de una cuenta de marca (`pageIdToken` de SmartTube). Nil en la cuenta personal.
    public var pageId: String?
    public var hasChannel: Bool
    /// La cuenta que la persona eligió en youtube.com/activate (`isSelected` de `accounts_list`).
    public var isActivated: Bool = false
    public var isDisabled: Bool = false

    public var isBrand: Bool { pageId != nil }

    public init(credentialId: String, name: String, pageId: String?, hasChannel: Bool) {
        self.credentialId = credentialId
        self.name = name
        self.pageId = pageId
        self.hasChannel = hasChannel
        id = "\(credentialId)/\(pageId ?? "principal")"
    }
}

/// Estado de las cuentas que ve la app.
public struct AccountSnapshot: Sendable, Equatable {
    public var accounts: [Account]
    public var selected: Account?
    public var isSignedIn: Bool { selected != nil }

    public init(accounts: [Account], selected: Account?) {
        self.accounts = accounts
        self.selected = selected
    }
}

// MARK: - /youtubei/v1/account/accounts_list

/// `AccountsList` + `AccountInt` de SmartTube. SmartTube lee solo la primera sección
/// (`contents[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[*].accountItem`); aquí se
/// recorren todas, porque las cuentas de marca pueden venir en otra sección.
enum AccountsListParser {
    struct Item: Decodable, Sendable {
        struct Photo: Decodable, Sendable { @Lenient var thumbnails: [ThumbnailItem]? }
        struct Endpoint: Decodable, Sendable {
            struct Select: Decodable, Sendable {
                struct SupportedToken: Decodable, Sendable {
                    struct PageId: Decodable, Sendable { @Lenient var pageId: String? }
                    @Lenient var pageIdToken: PageId?
                }
                @Lenient var supportedTokens: [SupportedToken]?
            }
            @Lenient var selectActiveIdentityEndpoint: Select?
        }
        @Lenient var accountName: YTText?
        @Lenient var accountByline: YTText?
        @Lenient var channelHandle: YTText?
        @Lenient var accountPhoto: Photo?
        @Lenient var isSelected: Bool?
        @Lenient var isDisabled: Bool?
        @Lenient var hasChannel: Bool?
        @Lenient var serviceEndpoint: Endpoint?

        var pageId: String? {
            serviceEndpoint?.selectActiveIdentityEndpoint?.supportedTokens?.lazy.compactMap { $0.pageIdToken?.pageId }.first
        }
    }

    /// Todas las `accountItem` de la respuesta, en orden.
    static func accounts(from data: Data, credentialId: String) throws -> [Account] {
        let root = try JSONSerialization.jsonObject(with: data)
        var raw: [Any] = []
        collect(root, into: &raw)
        var accounts: [Account] = []
        for object in raw {
            let itemData = try JSONSerialization.data(withJSONObject: object)
            guard let item = try? JSONDecoder().decode(Item.self, from: itemData), let name = item.accountName?.string else { continue }
            var account = Account(credentialId: credentialId, name: name, pageId: item.pageId, hasChannel: item.hasChannel ?? true)
            account.byline = item.accountByline?.string
            account.handle = item.channelHandle?.string
            account.avatar = (item.accountPhoto?.thumbnails ?? []).compactMap { thumb in
                thumb.url.map { Thumbnail(url: $0.hasPrefix("//") ? "https:" + $0 : $0, width: thumb.width?.value, height: thumb.height?.value) }
            }
            account.isActivated = item.isSelected ?? false
            account.isDisabled = item.isDisabled ?? false
            if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
        }
        return accounts
    }

    private static func collect(_ node: Any, into result: inout [Any]) {
        if let dict = node as? [String: Any] {
            if let item = dict["accountItem"] { result.append(item) }
            // Claves en orden fijo; el orden de las cuentas lo dan los arreglos `contents`.
            for key in dict.keys.sorted() where key != "accountItem" { collect(dict[key]!, into: &result) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &result) }
        }
    }
}
