import Combine
import Foundation
import PocketPortProtocol
import UIKit

@MainActor
final class DirectReceivingModel: ObservableObject {
    enum Activity: Equatable {
        case receiving(String, Int, Int), saving(String), saved(String), failed(String)
    }

    @Published private(set) var devices: [TrustedDevice] = []
    @Published private(set) var readiness = "Pair a Mac to receive files."
    @Published private(set) var activity: Activity?
    @Published private(set) var importEvent = UUID()
    @Published private(set) var settingsError: String?

    private let registry: DeviceRegistryStore
    private let store: ImportStore
    private let enabled: Bool
    private var foreground = false
    private var wifi: Bool?
    private var listener: DirectListener?
    private var listening: Task<Void, Never>?
    private var connections: [UUID: Task<Void, Never>] = [:]
    private var fileConnection: UUID?
    private var statusTimeout: Task<Void, Never>?

    init(store: ImportStore, enabled: Bool = true, registry: DeviceRegistryStore? = nil) {
        self.store = store
        self.enabled = enabled
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PairedComputers", isDirectory: true)
        self.registry = registry ?? DeviceRegistryStore(directory: directory)
    }

    func updateAvailability(foreground: Bool, wifi: Bool?) {
        guard enabled else { return }
        guard self.foreground != foreground || self.wifi != wifi else { return }
        self.foreground = foreground
        self.wifi = wifi
        restart()
    }

    func refreshSettings() {
        do {
            devices = try registry.load().devices
            settingsError = nil
        } catch {
            settingsError = "PocketPort couldn’t read its paired computers."
        }
    }

    func rename(_ device: TrustedDevice, to alias: String) {
        do {
            try registry.update { try $0.rename(id: device.id, to: alias) }
            refreshSettings()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func remove(_ device: TrustedDevice) {
        do {
            try registry.update { $0.remove(id: device.id) }
            restart()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func clearSettingsError() { settingsError = nil }

    func pair(service: LocalDiscovery.Service, code: String,
              confirm: (DirectIdentity) async -> Bool) async throws {
        guard enabled, wifi != false else { throw DirectError.offline }
        let credentials = try credentials()
        let socket = DirectSocket(endpoint: service.endpoint, timeout: 60)
        defer { socket.close() }
        try await socket.start()
        defer { restart() }
        _ = try await PairVerification.pairAsPhone(socket: socket, code: code, credentials: credentials,
                                                  confirm: confirm) { identity in
            _ = try self.registry.update { try $0.pair(identity) }
        }
    }

    func retryReceiving() { restart() }

    private func credentials() throws -> DeviceCredentials {
        let device = UIDevice.current
        return try registry.credentials(name: device.name, platform: device.userInterfaceIdiom == .pad ? "iPadOS" : "iOS")
    }

    private func restart() {
        stopReceiving()
        refreshSettings()
        guard settingsError == nil else { readiness = "Paired computers are unavailable."; return }
        guard !devices.isEmpty else { readiness = "Pair a Mac to receive files."; return }
        guard foreground, wifi != false else {
            readiness = wifi == false ? "Connect to Wi-Fi to receive files." : "Open PocketPort to receive files."
            return
        }
        do {
            let credentials = try credentials()
            let tls = DirectTLS(credentials: credentials, trustedIDs: Set(devices.map(\.id)))
            let listener = try DirectListener(name: credentials.identity.serviceName, type: LocalDiscovery.receiving, tls: tls)
            self.listener = listener
            readiness = "Starting Wi-Fi receiver…"
            listening = Task { [weak self] in
                do {
                    try await listener.start { [weak self, weak listener] error in
                        Task { @MainActor [weak self, weak listener] in
                            guard let listener, self?.listener === listener else { return }
                            self?.stopReceiving()
                            self?.readiness = error.localizedDescription
                        }
                    }
                    guard let self, self.listener === listener, !Task.isCancelled else { return }
                    self.readiness = "Ready to receive while PocketPort is open."
                    for await connection in listener.connections {
                        guard self.listener === listener, !Task.isCancelled else { connection.cancel(); return }
                        if self.connections.count >= 4 { connection.cancel(); continue }
                        self.accept(listener.accept(connection, timeout: 105))
                    }
                } catch {
                    guard self?.listener === listener else { return }
                    self?.stopReceiving()
                    self?.readiness = error.localizedDescription
                }
            }
        } catch {
            readiness = error.localizedDescription
        }
    }

    private func stopReceiving() {
        listener?.close()
        listener = nil
        listening?.cancel()
        listening = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        fileConnection = nil
        if case .receiving = activity { setActivity(.failed("Transfer interrupted. Keep PocketPort open and try again.")) }
        if case .saving = activity { setActivity(.failed("Transfer interrupted. Keep PocketPort open and try again.")) }
    }

    private func accept(_ socket: DirectSocket) {
        let connectionID = UUID()
        connections[connectionID] = Task { [weak self] in
            guard let self else { socket.close(); return }
            defer {
                socket.close()
                self.connections[connectionID] = nil
                if self.fileConnection == connectionID { self.fileConnection = nil }
            }
            do {
                try await socket.start()
                let sender = try socket.peerID()
                try self.verifySender(sender)
                let message = try await socket.read(DirectControl.self)
                switch message.kind {
                case .ping:
                    try await socket.write(DirectControl(.pong))
                    try? self.registry.update { $0.seen(id: sender) }
                case .offer:
                    guard let offer = message.offer, message.id == offer.id else { throw DirectError.badMessage }
                    guard self.fileConnection == nil else {
                        try await socket.write(DirectControl(.busy, id: offer.id))
                        return
                    }
                    self.fileConnection = connectionID
                    try await self.receive(offer, sender: sender, over: socket)
                default: throw DirectError.badMessage
                }
            } catch {
                if self.fileConnection == connectionID, !Task.isCancelled {
                    self.setActivity(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func verifySender(_ id: String) throws {
        try Task.checkCancellation()
        guard foreground, try registry.load().devices.contains(where: { $0.id == id }) else {
            throw DirectError.authentication
        }
    }

    private func receive(_ offer: DirectOffer, sender: String, over socket: DirectSocket) async throws {
        do { _ = try offer.validate() }
        catch {
            try? await socket.write(DirectControl(.invalidFile, id: offer.id))
            throw error
        }
        let record: ImportRecord
        do {
            if let saved = try await store.existingDirect(offer, senderID: sender) {
                record = saved
            } else {
                setActivity(.receiving(offer.filename, 0, offer.byteCount))
                let download: DownloadedFile
                do {
                    let (bytes, metadata) = try await DirectFileWire.fetch(offer, over: socket) { received in
                        self.setActivity(.receiving(offer.filename, received, offer.byteCount))
                    }
                    download = DownloadedFile(data: bytes, metadata: metadata)
                } catch DirectError.badMessage {
                    try? await socket.write(DirectControl(.invalidFile, id: offer.id))
                    throw DirectError.failed("This download couldn’t be verified.")
                }
                try verifySender(sender)
                setActivity(.saving(offer.filename))
                record = try await store.commitDirect(download, offer: offer, senderID: sender)
                importEvent = UUID()
            }
        } catch DirectError.conflict {
            try? await socket.write(DirectControl(.conflict, id: offer.id))
            throw DirectError.conflict
        } catch {
            if error is CocoaError || error is DecodingError || error is EncodingError {
                try? await socket.write(DirectControl(.saveFailed, id: offer.id))
                throw DirectError.failed("Couldn’t save this file. Check available storage and try again.")
            }
            throw error
        }
        try verifySender(sender)
        setActivity(.saved(record.filename))
        try? registry.update { $0.seen(id: sender) }
        try await socket.write(DirectControl(.receipt, id: offer.id))
    }

    func dismissActivity() {
        statusTimeout?.cancel()
        activity = nil
    }

    private func setActivity(_ next: Activity) {
        statusTimeout?.cancel()
        activity = next
        switch next {
        case .saved, .failed:
            statusTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                if !Task.isCancelled { self?.activity = nil }
            }
        case .receiving, .saving: break
        }
    }
}
