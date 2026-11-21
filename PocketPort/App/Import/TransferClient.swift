import Foundation
import Network
import PocketPortProtocol
#if canImport(UIKit)
import UIKit
#endif

struct DownloadedFile: Sendable {
    let data: Data
    let metadata: ShareMetadata
}

enum TransferError: Error, Equatable {
    case expired
    case unavailable
    case localNetworkDenied
    case unreachable
    case incomplete
}

protocol ShareTransferring: Sendable {
    func download(_ link: ShareLink) async throws -> DownloadedFile
    func acknowledge(_ link: ShareLink) async throws
}

struct TransferClient: ShareTransferring {
    var protocolClasses: [AnyClass] = []

    func download(_ link: ShareLink) async throws -> DownloadedFile {
        let diagnostic = LocalNetworkDiagnostic(link: link)
        let session = makeSession(timeout: 65, diagnostic: diagnostic)
        defer {
            session.invalidateAndCancel()
            diagnostic.stop()
        }
        var reachedResponse = false
        do {
            let (bytes, response) = try await session.bytes(for: request(for: link.downloadURL, link: link))
            reachedResponse = true
            let headers = try Self.validate(response)
            var data = Data()
            data.reserveCapacity(headers.length)
            for try await byte in bytes {
                guard data.count < headers.length else { throw TransferError.incomplete }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard data.count == headers.length,
                  ShareMetadata.digest(of: data) == headers.metadata.sha256,
                  headers.metadata.format?.requiresUTF8 != true || String(data: data, encoding: .utf8) != nil else {
                throw TransferError.incomplete
            }
            return DownloadedFile(data: data, metadata: headers.metadata)
        } catch let error as TransferError {
            throw error
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if reachedResponse { throw TransferError.incomplete }
            if link.isExpired(at: Date()) { throw TransferError.expired }
            // A waiting connection can report denial while the system alert is
            // still on screen. Keep waiting and classify only on terminal failure.
            let denied = await diagnostic.denialAfterFailure()
            try Task.checkCancellation()
            if denied, await Self.isForeground {
                throw TransferError.localNetworkDenied
            }
            throw TransferError.unreachable
        }
    }

    func acknowledge(_ link: ShareLink) async throws {
        let session = makeSession(timeout: 3)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.bytes(for: request(for: link.acknowledgmentURL, link: link, method: "POST"))
        switch (response as? HTTPURLResponse)?.statusCode {
        case 204: return
        case 404: throw TransferError.unavailable
        case 410: throw TransferError.expired
        default: throw TransferError.unreachable
        }
    }

    static func validate(_ response: URLResponse) throws -> (length: Int, metadata: ShareMetadata) {
        guard let response = response as? HTTPURLResponse else { throw TransferError.incomplete }
        switch response.statusCode {
        case 200: break
        case 404: throw TransferError.unavailable
        case 410: throw TransferError.expired
        default: throw TransferError.incomplete
        }
        guard response.value(forHTTPHeaderField: "Content-Encoding") == nil,
              let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
              let length = Int(contentLength),
              String(length) == contentLength else {
            throw TransferError.incomplete
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String {
                result[key] = value
            }
        }
        guard let metadata = try? ShareMetadata(headers: headers),
              let format = metadata.format,
              (0...format.maximumByteCount).contains(length),
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased() == format.contentType(filename: metadata.filename)
        else { throw TransferError.incomplete }
        return (length, metadata)
    }

    private func request(for url: URL, link: ShareLink, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue(link.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    @MainActor
    private static var isForeground: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    private func makeSession(timeout: TimeInterval, diagnostic: LocalNetworkDiagnostic? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: TransferDelegate(diagnostic: diagnostic), delegateQueue: nil)
    }
}

private final class TransferDelegate: NSObject, URLSessionTaskDelegate {
    private let diagnostic: LocalNetworkDiagnostic?

    init(diagnostic: LocalNetworkDiagnostic?) {
        self.diagnostic = diagnostic
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        diagnostic?.start()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class LocalNetworkDiagnostic: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PocketPort.LocalNetworkDiagnostic")
    private let link: ShareLink
    private var connection: NWConnection?
    private var stopped = false

    init(link: ShareLink) {
        self.link = link
    }

    func start() {
        queue.async { self.startIfNeeded() }
    }

    func denialAfterFailure() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.startIfNeeded()
                if self.isDenied {
                    continuation.resume(returning: true)
                } else {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                        continuation.resume(returning: self.isDenied)
                    }
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private var isDenied: Bool {
        connection?.currentPath?.unsatisfiedReason == .localNetworkDenied
    }

    private func startIfNeeded() {
        guard !stopped, connection == nil, let port = NWEndpoint.Port(rawValue: UInt16(link.port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(link.host), port: port, using: .tcp)
        self.connection = connection
        connection.start(queue: queue)
    }
}
