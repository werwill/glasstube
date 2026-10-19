import Foundation

/// Registro a stderr; `verbose` lo activa el CLI con `-v`.
public enum Log {
    nonisolated(unsafe) public static var verbose = false

    public static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("· \(message())\n".utf8))
    }

    public static func info(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

public struct HTTPError: Error, CustomStringConvertible {
    public let status: Int
    public let url: String
    public let body: String
    public var description: String { "HTTP \(status) en \(url): \(body.prefix(300))" }
}

/// Envoltura mínima sobre URLSession (el equivalente de Retrofit + OkHttp en SmartTube).
public final class HTTP: @unchecked Sendable {
    public static let shared = HTTP()

    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Equivalente al cookie "SOCS=CAE=" de VisitorApi: rechaza el muro de consentimiento de cookies (UE).
        if let cookie = HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SOCS", .value: "CAE=", .secure: "TRUE"]) {
            config.httpCookieStorage?.setCookie(cookie)
        }
        session = URLSession(configuration: config)
    }

    @discardableResult
    public func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                        timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        Log.debug("\(method) \(url.host ?? "")\(url.path) → \(http.statusCode) (\(data.count) B)")
        return (data, http)
    }

    public func string(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> String {
        let (data, response) = try await request(url, method: method, headers: headers, body: body)
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, url: url.absoluteString, body: text)
        }
        return text
    }
}

/// Caché en disco en ~/Library/Caches/Glasstube (JS del player crudo y preprocesado).
public enum DiskCache {
    public static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Glasstube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func fileURL(section: String, key: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        let dir = directory.appendingPathComponent(section, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(safeKey)
    }

    public static func load(section: String, key: String) -> String? {
        try? String(contentsOf: fileURL(section: section, key: key), encoding: .utf8)
    }

    public static func store(section: String, key: String, value: String) {
        try? value.write(to: fileURL(section: section, key: key), atomically: true, encoding: .utf8)
    }

    public static func clear(section: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(section, isDirectory: true))
    }
}

extension String {
    /// Primer grupo de captura de `pattern`, o nil.
    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}

extension URLComponents {
    func value(_ name: String) -> String? { queryItems?.first { $0.name == name }?.value }

    /// Reemplaza o añade un parámetro codificando todo lo que no sea "unreserved" (RFC 3986),
    /// para que `+`, `/` o `=` de firmas y tokens no cambien de significado en el servidor.
    mutating func set(_ name: String, _ value: String?) {
        guard let value else { return }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        var items = percentEncodedQueryItems ?? []
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index].value = encoded
        } else {
            items.append(URLQueryItem(name: name, value: encoded))
        }
        percentEncodedQueryItems = items
    }
}
