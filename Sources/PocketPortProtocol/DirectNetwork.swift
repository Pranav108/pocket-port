import Foundation
import Network
import Security

public enum LocalDiscovery {
    public static let pairing = "_pp-pair._tcp"
    public static let receiving = "_pp-file._tcp"
    static let queue = DispatchQueue(label: "dev.pocketport.direct", qos: .userInitiated)

    public struct Service: Identifiable, Sendable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: NWEndpoint { endpoint }
    }

    public static func browse(type: String, seconds: TimeInterval = 2.5, names: Set<String> = []) async throws -> [Service] {
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = BrowseState(continuation, browser: browser)
                browser.stateUpdateHandler = { status in
                    switch status {
                    case .waiting(let error), .failed(let error): state.finish(.failure(map(error)))
                    case .cancelled: state.finish(.failure(DirectError.cancelled))
                    default: break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    state.services = results.compactMap { result in
                        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                        return Service(name: name, endpoint: result.endpoint)
                    }.sorted { $0.name < $1.name }
                    if !names.isEmpty, names.isSubset(of: Set(state.services.map(\.name))) {
                        state.finish(.success(state.services))
                    }
                }
                queue.asyncAfter(deadline: .now() + seconds) { state.finish(.success(state.services)) }
                browser.start(queue: queue)
                if Task.isCancelled { browser.cancel() }
            }
        } onCancel: {
            browser.cancel()
        }
    }

    static func parameters(tls: NWProtocolTLS.Options? = nil, wifiOnly: Bool = true) -> NWParameters {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        if wifiOnly { parameters.requiredInterfaceType = .wifi }
        return parameters
    }

    static func map(_ error: NWError) -> DirectError {
        switch error {
        case .dns(-65570):
            return .network("Local Network access is denied. Allow it in Settings and try again.")
        case .tls:
            return .authentication
        case .posix(.ETIMEDOUT):
            return .timeout
        default:
            return .offline
        }
    }

    private final class BrowseState: @unchecked Sendable {
        var services: [Service] = []
        var continuation: CheckedContinuation<[Service], any Error>?
        let browser: NWBrowser

        init(_ continuation: CheckedContinuation<[Service], any Error>, browser: NWBrowser) {
            self.continuation = continuation
            self.browser = browser
        }

        func finish(_ result: Result<[Service], any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            browser.browseResultsChangedHandler = nil
            browser.stateUpdateHandler = nil
            browser.cancel()
            continuation.resume(with: result)
        }
    }
}

public struct DirectTLS: Sendable {
    public let credentials: DeviceCredentials
    public let trustedIDs: Set<String>

    public init(credentials: DeviceCredentials, trustedIDs: Set<String>) {
        self.credentials = credentials
        self.trustedIDs = trustedIDs
    }

    func options() -> NWProtocolTLS.Options {
        let result = NWProtocolTLS.Options()
        let options = result.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, credentials.tlsIdentity)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_add_tls_application_protocol(options, "pocketport-file/1")
        let pins = trustedIDs
        sec_protocol_options_set_verify_block(options, { _, wrapped, complete in
            let trust = sec_trust_copy_ref(wrapped).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first, let id = Self.certificateID(certificate) else {
                complete(false)
                return
            }
            complete(pins.contains(id))
        }, LocalDiscovery.queue)
        return result
    }

    private static func certificateID(_ certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data?, bytes.count == 65 else { return nil }
        return ShareMetadata.digest(of: bytes)
    }

    static func peerID(on connection: NWConnection) throws -> String {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let alpn = sec_protocol_metadata_get_negotiated_protocol(tls.securityProtocolMetadata),
              String(cString: alpn) == "pocketport-file/1" else { throw DirectError.authentication }
        var first = true
        var id: String?
        _ = sec_protocol_metadata_access_peer_certificate_chain(tls.securityProtocolMetadata) { certificate in
            guard first else { return }
            first = false
            id = certificateID(sec_certificate_copy_ref(certificate).takeRetainedValue())
        }
        guard let id else { throw DirectError.authentication }
        return id
    }
}

public final class DirectSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let expired = OSAllocatedFlag()
    private let timer: DispatchWorkItem

    public convenience init(endpoint: NWEndpoint, tls: DirectTLS? = nil, timeout: TimeInterval) {
        self.init(connection: NWConnection(to: endpoint, using: LocalDiscovery.parameters(tls: tls?.options())),
                  timeout: timeout)
    }

    init(connection: NWConnection, timeout: TimeInterval) {
        self.connection = connection
        let flag = expired
        timer = DispatchWorkItem { [weak connection] in
            flag.set()
            connection?.cancel()
        }
        LocalDiscovery.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    deinit { close() }

    public func close() {
        timer.cancel()
        connection.cancel()
    }

    public func start(handshakeTimeout: TimeInterval = 8) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result = OneResult(continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: result.finish(.success(()))
                    case .failed(let error), .waiting(let error): result.finish(.failure(LocalDiscovery.map(error)))
                    case .cancelled: result.finish(.failure(self?.closedError ?? DirectError.cancelled))
                    default: break
                    }
                }
                connection.start(queue: LocalDiscovery.queue)
                LocalDiscovery.queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                    if result.finish(.failure(DirectError.timeout)) { self?.close() }
                }
                if Task.isCancelled { close() }
            }
        } onCancel: { close() }
    }

    public func peerID() throws -> String { try DirectTLS.peerID(on: connection) }

    public func send(_ bytes: Data) async throws {
        if bytes.isEmpty { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: self.expired.value ? DirectError.timeout : LocalDiscovery.map(error)) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { close() }
    }

    public func read(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { bytes, _, _, error in
                    if let bytes, bytes.count == count, error == nil { continuation.resume(returning: bytes) }
                    else if let error, !self.expired.value { continuation.resume(throwing: LocalDiscovery.map(error)) }
                    else { continuation.resume(throwing: self.closedError) }
                }
            }
        } onCancel: { close() }
    }

    private var closedError: DirectError { expired.value ? .timeout : .offline }

    public func writeFrame(_ payload: Data) async throws {
        guard payload.count <= 16_384 else { throw DirectError.badMessage }
        let size = UInt32(payload.count)
        let prefix = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        try await send(prefix + payload)
    }

    public func readFrame() async throws -> Data {
        let header = try await read(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= 16_384 else { throw DirectError.badMessage }
        return try await read(Int(size))
    }

    public func write<T: Encodable>(_ message: T) async throws {
        try await writeFrame(JSONEncoder().encode(message))
    }

    public func read<T: Decodable>(_ type: T.Type) async throws -> T {
        let bytes = try await readFrame()
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw DirectError.badMessage }
    }
}

public final class DirectListener: @unchecked Sendable {
    private let listener: NWListener
    public let connections: AsyncStream<NWConnection>
    private let incoming: AsyncStream<NWConnection>.Continuation

    public convenience init(name: String, type: String, tls: DirectTLS? = nil) throws {
        try self.init(parameters: LocalDiscovery.parameters(tls: tls?.options()),
                      service: .init(name: name, type: type, domain: "local."))
    }

    init(parameters: NWParameters, service: NWListener.Service? = nil) throws {
        listener = try NWListener(using: parameters)
        listener.service = service
        (connections, incoming) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(4))
    }

    deinit { close() }
    public var port: NWEndpoint.Port? { listener.port }

    public func start(onFailure: @escaping @Sendable (DirectError) -> Void = { _ in }) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result = OneResult(continuation)
                let queue = incoming
                listener.newConnectionHandler = { connection in
                    switch queue.yield(connection) {
                    case .dropped(let dropped): dropped.cancel()
                    case .terminated: connection.cancel()
                    case .enqueued: break
                    @unknown default: connection.cancel()
                    }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: result.finish(.success(()))
                    case .waiting(let error), .failed(let error):
                        let failure = LocalDiscovery.map(error)
                        result.finish(.failure(failure))
                        onFailure(failure)
                        queue.finish()
                    case .cancelled:
                        result.finish(.failure(DirectError.cancelled))
                        queue.finish()
                    default: break
                    }
                }
                listener.start(queue: LocalDiscovery.queue)
                LocalDiscovery.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if result.finish(.failure(DirectError.timeout)) { self?.close() }
                }
                if Task.isCancelled { close() }
            }
        } onCancel: { close() }
    }

    public func accept(_ connection: NWConnection, timeout: TimeInterval) -> DirectSocket {
        DirectSocket(connection: connection, timeout: timeout)
    }

    public func close() {
        listener.cancel()
        incoming.finish()
    }
}

private final class OneResult: @unchecked Sendable {
    // All invocations are serialized on LocalDiscovery.queue.
    private var continuation: CheckedContinuation<Void, any Error>?
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

    @discardableResult
    func finish(_ value: Result<Void, any Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: value)
        return true
    }
}

private final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
