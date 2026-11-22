import CryptoKit
import Foundation

public struct DirectOffer: Codable, Sendable {
    public static let lifetime: Int64 = 120
    public let id: UUID
    public let expiresAt: Int64
    public let filename: String
    public let project: String?
    public let sha256: String
    public let byteCount: Int

    public init(id: UUID, metadata: ShareMetadata, byteCount: Int, now: Date = Date()) {
        self.id = id
        expiresAt = Int64(now.timeIntervalSince1970) + Self.lifetime
        filename = metadata.filename
        project = metadata.project
        sha256 = metadata.sha256
        self.byteCount = byteCount
    }

    public func validate(now: Date = Date()) throws -> ShareMetadata {
        let seconds = Int64(now.timeIntervalSince1970)
        guard expiresAt >= seconds - 15, expiresAt <= seconds + Self.lifetime + 15 else {
            throw DirectError.failed("The transfer invitation expired or the device clocks disagree.")
        }
        let metadata = try ShareMetadata(filename: filename, project: project, sha256: sha256)
        guard !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let format = metadata.format, (0...format.maximumByteCount).contains(byteCount) else {
            throw DirectError.badMessage
        }
        return metadata
    }

    public func importID(senderID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("PocketPort import v1 \(senderID) \(id.uuidString.lowercased())".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public struct DirectControl: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ping, pong, offer, fetch, receipt, rejected, busy, conflict, invalidFile, saveFailed
    }

    public let kind: Kind
    public let id: UUID?
    public let offer: DirectOffer?

    public init(_ kind: Kind, id: UUID? = nil, offer: DirectOffer? = nil) {
        self.kind = kind
        self.id = id
        self.offer = offer
    }

    func checkID(_ expected: UUID) throws {
        guard id == expected else { throw DirectError.badMessage }
        switch kind {
        case .busy: throw DirectError.busy
        case .conflict: throw DirectError.conflict
        case .saveFailed: throw DirectError.failed("The phone could not save the file. Check its available storage.")
        case .invalidFile: throw DirectError.failed("The phone could not verify the file.")
        case .rejected: throw DirectError.authentication
        default: break
        }
    }
}

public enum DirectFileWire {
    static let chunk = 65_536

    public static func ping(_ socket: DirectSocket) async throws {
        try await socket.write(DirectControl(.ping))
        guard try await socket.read(DirectControl.self).kind == .pong else { throw DirectError.badMessage }
    }

    /// The sender only releases file bytes after the authenticated receiver requests this offer.
    public static func send(_ bytes: Data, offer: DirectOffer, over socket: DirectSocket,
                            progress: (Int) -> Void = { _ in }) async throws {
        _ = try offer.validate()
        guard bytes.count == offer.byteCount else { throw DirectError.badMessage }
        try await socket.write(DirectControl(.offer, id: offer.id, offer: offer))
        let reply = try await socket.read(DirectControl.self)
        try reply.checkID(offer.id)
        if reply.kind == .receipt { return } // The receiver already persisted this exact transfer.
        guard reply.kind == .fetch else { throw DirectError.badMessage }
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            try Task.checkCancellation()
            let end = min(start + chunk, bytes.count)
            try await socket.send(bytes.subdata(in: start..<end))
            progress(end)
        }
        let receipt = try await socket.read(DirectControl.self)
        try receipt.checkID(offer.id)
        guard receipt.kind == .receipt else { throw DirectError.badMessage }
    }

    public static func fetch(_ offer: DirectOffer, over socket: DirectSocket,
                             progress: (Int) -> Void = { _ in }) async throws -> (Data, ShareMetadata) {
        let metadata = try offer.validate()
        try await socket.write(DirectControl(.fetch, id: offer.id))
        var bytes = Data()
        bytes.reserveCapacity(offer.byteCount)
        while bytes.count < offer.byteCount {
            try Task.checkCancellation()
            let count = min(chunk, offer.byteCount - bytes.count)
            bytes.append(try await socket.read(count))
            progress(bytes.count)
        }
        try validate(bytes, against: metadata)
        return (bytes, metadata)
    }

    public static func validate(_ bytes: Data, against metadata: ShareMetadata) throws {
        guard let format = metadata.format, bytes.count <= format.maximumByteCount,
              ShareMetadata.digest(of: bytes) == metadata.sha256,
              !format.requiresUTF8 || String(data: bytes, encoding: .utf8) != nil else {
            throw DirectError.badMessage
        }
    }
}
