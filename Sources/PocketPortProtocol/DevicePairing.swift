@_implementationOnly import CPocketPortPairing
import CryptoKit
import Foundation

public enum PairVerification {
    public static let lifetime: TimeInterval = 120
    public static let maxAttempts = 5

    public static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func normalize(_ input: String) throws -> String {
        let digits = input.filter { $0 != "-" && $0 != " " }
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw DirectError.failed("Enter the six-digit code displayed on your Mac.")
        }
        return digits
    }

    public static func pairAsPhone(socket: DirectSocket, code: String, credentials: DeviceCredentials,
                                   confirm: (DirectIdentity) async -> Bool,
                                   save: (DirectIdentity) throws -> Void) async throws -> DirectIdentity {
        let handshake = try await exchange(socket, code: normalize(code), server: false)
        let computer = try await handshake.readIdentity(from: socket, label: "mac-identity")
        guard await confirm(computer) else { throw DirectError.cancelled }
        try Task.checkCancellation()
        try await handshake.sendIdentity(credentials, to: socket, label: "phone-identity")
        let accepted: Bool = try await handshake.read(from: socket, label: "mac-confirmed")
        guard accepted else { throw DirectError.authentication }
        try Task.checkCancellation()
        try save(computer)
        try await handshake.send(true, to: socket, label: "phone-confirmed")
        return computer
    }

    public static func pairAsMac(socket: DirectSocket, code: String, credentials: DeviceCredentials,
                                 approve: (DirectIdentity) throws -> Void) async throws -> DirectIdentity {
        let handshake = try await exchange(socket, code: normalize(code), server: true)
        try await handshake.sendIdentity(credentials, to: socket, label: "mac-identity")
        let phone = try await handshake.readIdentity(from: socket, label: "phone-identity")
        try Task.checkCancellation()
        try approve(phone)
        try await handshake.send(true, to: socket, label: "mac-confirmed")
        let persisted: Bool = try await handshake.read(from: socket, label: "phone-confirmed")
        guard persisted else { throw DirectError.authentication }
        return phone
    }

    private static func transcriptHash(_ transcript: [Data]) -> Data {
        var framed = Data()
        for part in transcript {
            let size = UInt16(part.count)
            framed.append(contentsOf: [UInt8(size >> 8), UInt8(size & 255)])
            framed.append(part)
        }
        return Data(SHA256.hash(data: framed))
    }

    private static func exchange(_ socket: DirectSocket, code: String, server: Bool) async throws -> Handshake {
        let pake = try PairPAKE(code: code, server: server)
        let phoneOne: Data, macOne: Data, macTwo: Data, phoneTwo: Data
        if server {
            phoneOne = try await socket.readFrame()
            try pake.read(round: 1, phoneOne)
            macOne = try pake.write(round: 1)
            try await socket.writeFrame(macOne)
            macTwo = try pake.write(round: 2)
            try await socket.writeFrame(macTwo)
            phoneTwo = try await socket.readFrame()
            try pake.read(round: 2, phoneTwo)
        } else {
            phoneOne = try pake.write(round: 1)
            try await socket.writeFrame(phoneOne)
            macOne = try await socket.readFrame()
            try pake.read(round: 1, macOne)
            macTwo = try await socket.readFrame()
            try pake.read(round: 2, macTwo)
            phoneTwo = try pake.write(round: 2)
            try await socket.writeFrame(phoneTwo)
        }
        let transcript = transcriptHash([phoneOne, macOne, macTwo, phoneTwo])
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: try pake.secret()), salt: transcript,
                                        info: Data("PocketPort ECJPAKE P256 v1".utf8), outputByteCount: 32)
        return Handshake(key: key, transcript: transcript)
    }

    private struct Handshake {
        let key: SymmetricKey
        let transcript: Data

        private struct SignedIdentity: Codable {
            let identity: DirectIdentity
            let signature: Data
        }

        func sendIdentity(_ credentials: DeviceCredentials, to socket: DirectSocket, label: String) async throws {
            let signature = try credentials.sign(proofInput(label))
            try await send(SignedIdentity(identity: credentials.identity, signature: signature), to: socket, label: label)
        }

        func readIdentity(from socket: DirectSocket, label: String) async throws -> DirectIdentity {
            let record: SignedIdentity = try await read(from: socket, label: label)
            try record.identity.validate()
            let key = try P256.Signing.PublicKey(x963Representation: record.identity.publicKey)
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: record.signature),
                  key.isValidSignature(signature, for: proofInput(label)) else { throw DirectError.authentication }
            return record.identity
        }

        private func proofInput(_ label: String) -> Data {
            Data(("PocketPort identity proof v1 " + label + "\0").utf8) + transcript
        }

        func send<T: Encodable>(_ message: T, to socket: DirectSocket, label: String) async throws {
            let binding = Data(label.utf8)
            let stepKey = step(binding)
            let box = try AES.GCM.seal(JSONEncoder().encode(message), using: stepKey, authenticating: binding)
            guard let bytes = box.combined else { throw DirectError.authentication }
            try await socket.writeFrame(bytes)
        }

        func read<T: Decodable>(from socket: DirectSocket, label: String) async throws -> T {
            let bytes = try await socket.readFrame()
            let binding = Data(label.utf8)
            do {
                let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: step(binding), authenticating: binding)
                return try JSONDecoder().decode(T.self, from: clear)
            } catch {
                throw DirectError.authentication
            }
        }

        private func step(_ label: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: label, outputByteCount: 32)
        }
    }
}

final class PairPAKE {
    private let context: OpaquePointer

    init(code: String, server: Bool) throws {
        // Hashing ensures six zeros is still a nonzero scalar. Only EC J-PAKE exposes a
        // password-dependent message to the network, never the code or this preimage.
        let password = Data(SHA256.hash(data: Data(("PocketPort pairing v1\0" + code).utf8)))
        let pointer = password.withUnsafeBytes { bytes in
            pocketport_pake_create(server ? 1 : 0, bytes.bindMemory(to: UInt8.self).baseAddress, password.count)
        }
        guard let pointer else { throw DirectError.authentication }
        context = pointer
    }

    deinit { pocketport_pake_free(context) }

    func write(round: Int32) throws -> Data {
        try output { pocketport_pake_write(context, round, $0, $1, $2) }
    }

    func read(round: Int32, _ input: Data) throws {
        guard (1...1024).contains(input.count) else { throw DirectError.badMessage }
        let status = input.withUnsafeBytes {
            pocketport_pake_read(context, round, $0.bindMemory(to: UInt8.self).baseAddress, input.count)
        }
        guard status == 0 else { throw DirectError.authentication }
    }

    func secret() throws -> Data {
        try output { pocketport_pake_secret(context, $0, $1, $2) }
    }

    private func output(_ body: (UnsafeMutablePointer<UInt8>, Int, UnsafeMutablePointer<Int>) -> Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 1024)
        var size = 0
        guard body(&bytes, bytes.count, &size) == 0, (1...bytes.count).contains(size) else {
            throw DirectError.authentication
        }
        return Data(bytes.prefix(size))
    }
}
