import CryptoKit
import Darwin
import Foundation
import Security

public enum DirectError: LocalizedError {
    case authentication, badMessage, timeout, offline, busy, cancelled, conflict
    case credentials(OSStatus), network(String), failed(String)

    public var errorDescription: String? {
        switch self {
        case .authentication: return "Device verification failed. Check the code or pair this device again."
        case .badMessage: return "PocketPort received an invalid or incompatible message."
        case .timeout: return "The connection timed out."
        case .offline: return "Device unavailable. Open PocketPort and check Wi-Fi, Local Network access, and whether your network isolates devices."
        case .busy: return "The receiver is busy. Try again shortly."
        case .cancelled: return "The operation was cancelled."
        case .conflict: return "A conflicting device identity or transfer ID was received."
        case .credentials(let status): return "PocketPort could not access its Keychain credentials (\(status))."
        case .network(let detail), .failed(let detail): return detail
        }
    }
}

public struct DirectIdentity: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let platform: String
    public let publicKey: Data

    public var id: String { ShareMetadata.digest(of: publicKey) }
    public var serviceName: String { String(id.prefix(32)) }
    public var fingerprint: String { String(id.prefix(12)).uppercased() }

    public init(name: String, platform: String, publicKey: Data) {
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 128, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !platform.isEmpty, platform.utf8.count <= 24,
              platform.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else {
            throw DirectError.badMessage
        }
    }
}

public struct TrustedDevice: Codable, Hashable, Identifiable, Sendable {
    public let identity: DirectIdentity
    public var alias: String
    public let pairedAt: Date
    public var lastSeen: Date?
    public var id: String { identity.id }
}

public struct DeviceRegistry: Codable, Sendable {
    public private(set) var devices: [TrustedDevice] = []
    public private(set) var defaultID: String?
    private var pending: [PendingTransfer] = []

    public init() {}

    public static func validateAlias(_ value: String) throws -> String {
        let alias = value.lowercased()
        guard (1...40).contains(alias.utf8.count), alias != "all",
              alias.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !alias.hasPrefix("-"), !alias.hasSuffix("-") else {
            throw DirectError.failed("Aliases must use 1–40 letters, digits or hyphens. The alias ‘all’ is reserved.")
        }
        return alias
    }

    @discardableResult
    public mutating func pair(_ identity: DirectIdentity, alias requested: String? = nil, now: Date = Date()) throws -> TrustedDevice {
        try identity.validate()
        if let index = devices.firstIndex(where: { $0.id == identity.id }) {
            let old = devices[index]
            let alias = try requested.map { try uniqueAlias($0, excluding: old.id) } ?? old.alias
            devices[index] = TrustedDevice(identity: identity, alias: alias, pairedAt: old.pairedAt, lastSeen: now)
            return devices[index]
        }
        guard devices.count < 64 else { throw DirectError.failed("Remove a paired device before adding another.") }
        let alias = try requested.map { try uniqueAlias($0) } ?? nextAlias(for: identity.platform)
        let device = TrustedDevice(identity: identity, alias: alias, pairedAt: now, lastSeen: now)
        devices.append(device)
        return device
    }

    public func device(alias: String) throws -> TrustedDevice {
        guard let device = devices.first(where: { $0.alias == alias.lowercased() }) else {
            throw DirectError.failed("Unknown device alias ‘\(alias)’. Run pocketport devices to see paired devices.")
        }
        return device
    }

    public func targets(_ aliases: String?) throws -> [TrustedDevice]? {
        guard !devices.isEmpty else { throw DirectError.failed("No paired devices. Run pocketport pair first.") }
        if let aliases {
            if aliases.lowercased() == "all" { return devices }
            var seen = Set<String>()
            return try aliases.split(separator: ",", omittingEmptySubsequences: false).map { try device(alias: String($0)) }
                .filter { seen.insert($0.id).inserted }
        }
        if let defaultID, let device = devices.first(where: { $0.id == defaultID }) { return [device] }
        return devices.count == 1 ? devices : nil
    }

    public mutating func rename(id: String, to alias: String) throws {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { throw DirectError.authentication }
        devices[index].alias = try uniqueAlias(alias, excluding: id)
    }

    public mutating func setDefault(id: String?) {
        defaultID = id.flatMap { value in devices.contains(where: { $0.id == value }) ? value : nil }
    }

    public mutating func remove(id: String) {
        devices.removeAll { $0.id == id }
        pending.removeAll { $0.deviceID == id }
        if defaultID == id { defaultID = nil }
    }

    public mutating func seen(id: String, now: Date = Date()) {
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].lastSeen = now }
    }

    public mutating func transferID(deviceID: String, contentID: String, now: Date = Date()) throws -> UUID {
        guard devices.contains(where: { $0.id == deviceID }) else { throw DirectError.authentication }
        pending.removeAll { $0.expiresAt <= now }
        if let transfer = pending.first(where: { $0.deviceID == deviceID && $0.contentID == contentID }) {
            return transfer.id
        }
        guard pending.count < 1_000 else { throw DirectError.failed("Too many incomplete transfers. Try again after older sessions expire.") }
        let transfer = PendingTransfer(deviceID: deviceID, contentID: contentID, id: UUID(), expiresAt: now.addingTimeInterval(86_400))
        pending.append(transfer)
        return transfer.id
    }

    public mutating func finish(deviceID: String, id: UUID) {
        pending.removeAll { $0.deviceID == deviceID && $0.id == id }
        seen(id: deviceID)
    }

    private func uniqueAlias(_ name: String, excluding id: String? = nil) throws -> String {
        let alias = try Self.validateAlias(name)
        guard !devices.contains(where: { $0.alias == alias && $0.id != id }) else {
            throw DirectError.failed("The alias ‘\(alias)’ is already in use.")
        }
        return alias
    }

    private func nextAlias(for platform: String) -> String {
        let base: String
        switch platform.lowercased() {
        case "ios": base = "iphone"
        case "ipados": base = "ipad"
        case "macos": base = "mac"
        default: base = "device"
        }
        let used = Set(devices.map(\.alias))
        if !used.contains(base) { return base }
        return (2...(used.count + 2)).lazy.map { "\(base)-\($0)" }.first(where: { !used.contains($0) })!
    }

    private struct PendingTransfer: Codable, Sendable {
        let deviceID: String
        let contentID: String
        let id: UUID
        let expiresAt: Date
    }
}

public struct DeviceRegistryStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> DeviceRegistry { try locked { try read() } }

    public func update<T>(_ body: (inout DeviceRegistry) throws -> T) throws -> T {
        try locked {
            var registry = try read()
            let result = try body(&registry)
            try JSONEncoder().encode(registry).write(to: directory.appendingPathComponent("devices.json"), options: .atomic)
            return result
        }
    }

    public func credentials(name: String, platform: String) throws -> DeviceCredentials {
        try locked {
            // Missing credentials invalidate existing trust. Never silently rotate an established identity.
            let allowCreation = try read().devices.isEmpty
            return try DeviceCredentials.load(name: name, platform: platform, allowCreation: allowCreation)
        }
    }

    private func read() throws -> DeviceRegistry {
        do {
            return try JSONDecoder().decode(DeviceRegistry.self, from: Data(contentsOf: directory.appendingPathComponent("devices.json")))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DeviceRegistry()
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let handle = open(directory.appendingPathComponent("devices.lock").path, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0o600)
        guard handle >= 0 else { throw DirectError.failed("Unable to open the paired-device registry.") }
        defer { close(handle) }
        while flock(handle, LOCK_EX) != 0 {
            if errno != EINTR { throw DirectError.failed("Unable to lock the paired-device registry.") }
        }
        return try body()
    }
}

public struct DeviceCredentials: @unchecked Sendable {
    public let identity: DirectIdentity
    let tlsIdentity: sec_identity_t
    private let signingKey: P256.Signing.PrivateKey

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.pocketport.direct.v1",
        kSecAttrAccount as String: "p256-device-identity",
    ]

    static func load(name: String, platform: String, allowCreation: Bool) throws -> Self {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(lookup as CFDictionary, &item)
        if result == errSecSuccess {
            guard let data = item as? Data else { throw DirectError.credentials(errSecDecode) }
            return try Self(name: name, platform: platform, privateKey: P256.Signing.PrivateKey(x963Representation: data))
        }
        guard result == errSecItemNotFound, allowCreation else { throw DirectError.credentials(result) }
        let key = P256.Signing.PrivateKey()
        var entry = query
        entry[kSecValueData as String] = key.x963Representation
        #if os(iOS)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        let inserted = SecItemAdd(entry as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw DirectError.credentials(inserted) }
        return try Self(name: name, platform: platform, privateKey: key)
    }

    init(name: String, platform: String, privateKey: P256.Signing.PrivateKey) throws {
        let label = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(String.UnicodeScalarView(label.unicodeScalars.prefix(32)))
        identity = DirectIdentity(name: trimmed.isEmpty ? platform : trimmed, platform: platform,
                                  publicKey: privateKey.publicKey.x963Representation)
        try identity.validate()
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        let der = try SelfSignedCertificate.make(for: privateKey)
        guard let key = SecKeyCreateWithData(privateKey.x963Representation as CFData, attributes, nil),
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let identity = SecIdentityCreate(nil, certificate, key),
              let wrapped = sec_identity_create(identity) else { throw DirectError.credentials(errSecDecode) }
        tlsIdentity = wrapped
        signingKey = privateKey
    }

    func sign(_ data: Data) throws -> Data { try signingKey.signature(for: data).derRepresentation }
}

/// Minimal DER container for a P-256 TLS certificate. Trust is the peer's paired public key.
private enum SelfSignedCertificate {
    private static func field(_ tag: UInt8, _ body: Data) -> Data {
        if body.count < 128 { return Data([tag, UInt8(body.count)]) + body }
        let length = body.count <= 255 ? [UInt8(body.count)] : [UInt8(body.count >> 8), UInt8(body.count & 255)]
        return Data([tag, 0x80 | UInt8(length.count)] + length) + body
    }
    private static func sequence(_ body: Data) -> Data { field(0x30, body) }
    private static func bits(_ body: Data) -> Data { field(0x03, Data([0]) + body) }

    static func make(for key: P256.Signing.PrivateKey) throws -> Data {
        let ecdsaSHA256 = sequence(Data([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
        let ecP256 = sequence(Data([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]))
        let subject = sequence(field(0x31, sequence(Data([0x06, 0x03, 0x55, 0x04, 0x03]) + field(0x0c, Data("PocketPort device".utf8)))))
        let validity = sequence(field(0x17, Data("240101000000Z".utf8)) + field(0x18, Data("21000101000000Z".utf8)))
        let serial = field(0x02, Data([1]) + Data(SHA256.hash(data: key.publicKey.x963Representation).prefix(15)))
        let spki = sequence(ecP256 + bits(key.publicKey.x963Representation))
        let tbs = sequence(field(0xa0, Data([0x02, 0x01, 0x02])) + serial + ecdsaSHA256 + subject + validity + subject + spki)
        return sequence(tbs + ecdsaSHA256 + bits(try key.signature(for: tbs).derRepresentation))
    }
}
