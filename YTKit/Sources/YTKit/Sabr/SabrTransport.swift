import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// POST con lectura en flujo para SABR: `URLSessionDataDelegate` entrega el cuerpo por trozos (`didReceive data`)
/// y se pasan a un `AsyncThrowingStream`, para que `UMPDecoder.feed` vea las partes `MEDIA` conforme llegan en
/// lugar de esperar la respuesta completa (`URLSession.data`).
final class SabrTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SabrTransport()

    struct Response {
        let status: Int
        let body: AsyncThrowingStream<Data, Error>

        /// Para errores: junta hasta `limit` bytes del cuerpo.
        func text(limit: Int = 2048) async -> String {
            var data = Data()
            do {
                for try await chunk in body where data.count < limit { data.append(chunk) }
            } catch {}
            return String(decoding: data.prefix(limit), as: UTF8.self)
        }
    }

    private struct Pending {
        var response: CheckedContinuation<Int, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation
    }

    private let queue: OperationQueue
    private var session: URLSession!
    /// Solo se toca en `queue` (la cola del delegado).
    private var pending: [Int: Pending] = [:]

    override init() {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "glasstube.sabr.transport"
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // URLSession aplica el menor entre este y el `timeoutInterval` de cada petición (medido: 30 y 60 → 30 s;
        // 30 y 8 → 8 s): el tiempo de espera lo decide cada petición (`SabrOptions.requestTimeout`).
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Devuelve en cuanto llegan las cabeceras; el cuerpo sigue llegando por `body`. Cancelar la tarea que consume
    /// `body` (o la que espera aquí) cancela la petición.
    func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.dataTask(with: request)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation.onTermination = { _ in task.cancel() }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (response: CheckedContinuation<Int, Error>) in
                queue.addOperation {
                    self.pending[task.taskIdentifier] = Pending(response: response, body: continuation)
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
        return Response(status: status, body: stream)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        pending[dataTask.taskIdentifier]?.response?.resume(returning: status)
        pending[dataTask.taskIdentifier]?.response = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending[dataTask.taskIdentifier]?.body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { return }
        entry.response?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error {
            entry.body.finish(throwing: error)
        } else {
            entry.body.finish()
        }
    }
}
