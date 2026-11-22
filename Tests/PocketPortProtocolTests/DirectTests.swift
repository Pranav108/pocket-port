import CPocketPortPairing
import CryptoKit
import Foundation
import Network
import XCTest
@testable import PocketPortProtocol

final class DirectTests: XCTestCase {
    func testUpstreamPAKEVectorAndCodeNormalization() throws {
        XCTAssertEqual(pocketport_pake_self_test(), 0)
        XCTAssertEqual(try PairVerification.normalize("012-345"), "012345")
        XCTAssertEqual(try PairVerification.normalize("000000"), "000000")
        XCTAssertThrowsError(try PairVerification.normalize("२२२२२२"))
        XCTAssertThrowsError(try PairVerification.normalize("12345"))
        XCTAssertEqual(PairVerification.lifetime, 120)
        XCTAssertEqual(PairVerification.maxAttempts, 5)
    }

    func testCleanPairingAndWrongCodeOverLoopback() async throws {
        let mac = try credentials("Mac", platform: "macOS")
        let phone = try credentials("Phone", platform: "iOS")
        let listener = try makeListener()
        defer { listener.close() }
        try await listener.start()
        let approved = TestTrust()
        let host = Task {
            for await connection in listener.connections {
                let socket = listener.accept(connection, timeout: 4)
                defer { socket.close() }
                do {
                    try await socket.start()
                    let peer = try await PairVerification.pairAsMac(socket: socket, code: "004589", credentials: mac) {
                        approved.record($0)
                    }
                    return peer
                } catch { continue }
            }
            throw DirectError.timeout
        }
        defer { host.cancel() }

        let wrong = try await connect(listener)
        do {
            _ = try await PairVerification.pairAsPhone(socket: wrong, code: "004590", credentials: phone,
                                                       confirm: { _ in XCTFail("Wrong code authenticated"); return true },
                                                       save: { _ in XCTFail("Wrong code saved") })
            XCTFail("Pairing accepted the wrong code")
        } catch DirectError.authentication {}
        wrong.close()

        let cancelled = try await connect(listener)
        do {
            _ = try await PairVerification.pairAsPhone(socket: cancelled, code: "004589", credentials: phone,
                                                       confirm: { _ in false }, save: { _ in XCTFail("Cancelled pair saved") })
            XCTFail("Pairing accepted cancellation")
        } catch DirectError.cancelled {}
        cancelled.close()
        XCTAssertNil(approved.value)

        let correct = try await connect(listener)
        defer { correct.close() }
        let verified = try await PairVerification.pairAsPhone(socket: correct, code: "004589", credentials: phone,
                                                             confirm: { $0.id == mac.identity.id }, save: {
            XCTAssertEqual($0, mac.identity)
        })
        let remote = try await host.value
        XCTAssertEqual(verified, mac.identity)
        XCTAssertEqual(remote, phone.identity)
        XCTAssertEqual(approved.value, phone.identity)
    }

    func testRegistryAliasesPersistenceDefaultsRevocationAndRetryIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let one = try credentials("iPhone", platform: "iOS").identity
        let two = try credentials("iPhone", platform: "iOS").identity
        let tablet = try credentials("iPad", platform: "iPadOS").identity
        let first = DeviceRegistryStore(directory: directory)
        try first.update {
            XCTAssertEqual(try $0.pair(one).alias, "iphone")
            XCTAssertEqual(try $0.targets(nil)?.map(\.id), [one.id])
            XCTAssertEqual(try $0.pair(two).alias, "iphone-2")
            XCTAssertEqual(try $0.pair(tablet).alias, "ipad")
            XCTAssertEqual(try $0.pair(one).alias, "iphone")
            XCTAssertNil(try $0.targets(nil))
            XCTAssertThrowsError(try $0.rename(id: one.id, to: "IPAD"))
            XCTAssertThrowsError(try $0.targets("unknown"))
            XCTAssertThrowsError(try $0.targets("all,iphone"))
            try $0.rename(id: two.id, to: "spare")
            $0.setDefault(id: two.id)
        }
        let reopened = DeviceRegistryStore(directory: directory)
        let restored = try reopened.load()
        XCTAssertEqual(try restored.targets(nil)?.map(\.id), [two.id])
        XCTAssertEqual(try restored.targets("iphone,ipad,iphone")?.map(\.id), [one.id, tablet.id])
        XCTAssertEqual(try restored.targets("all")?.count, 3)
        let original = try first.update { try $0.transferID(deviceID: two.id, contentID: "example") }
        let retry = try reopened.update { try $0.transferID(deviceID: two.id, contentID: "example") }
        XCTAssertEqual(original, retry)
        try reopened.update {
            $0.finish(deviceID: two.id, id: retry)
            XCTAssertNotEqual(try $0.transferID(deviceID: two.id, contentID: "example"), retry)
            $0.remove(id: two.id)
            XCTAssertThrowsError(try $0.transferID(deviceID: two.id, contentID: "example"))
            XCTAssertNil($0.defaultID)
        }
        XCTAssertEqual(try first.load().devices.map(\.alias), ["iphone", "ipad"])
    }

    func testOfferExpiryDigestAndSenderScopedIdentifiers() throws {
        let now = Date(timeIntervalSince1970: 55_000)
        let bytes = Data("रिपोर्ट".utf8)
        let metadata = try ShareMetadata(filename: "रिपोर्ट Final.html", sha256: ShareMetadata.digest(of: bytes))
        let offer = DirectOffer(id: UUID(), metadata: metadata, byteCount: bytes.count, now: now)
        XCTAssertEqual(try offer.validate(now: now), metadata)
        XCTAssertThrowsError(try offer.validate(now: now.addingTimeInterval(136)))
        XCTAssertThrowsError(try offer.validate(now: now.addingTimeInterval(-16)))
        XCTAssertThrowsError(try DirectFileWire.validate(Data("changed".utf8), against: metadata))
        XCTAssertEqual(offer.importID(senderID: "mac-a"), offer.importID(senderID: "mac-a"))
        XCTAssertNotEqual(offer.importID(senderID: "mac-b"), offer.importID(senderID: "mac-a"))
        XCTAssertThrowsError(try DirectOffer(id: UUID(), metadata: metadata, byteCount: Int.max, now: now).validate(now: now))
        XCTAssertThrowsError(try ShareMetadata(filename: "../file.md", sha256: metadata.sha256))
    }

    func testPinnedTLSFileFetchAndDuplicateReceipt() async throws {
        let mac = try credentials("Mac", platform: "macOS")
        let phone = try credentials("Phone", platform: "iOS")
        let receiver = DirectTLS(credentials: phone, trustedIDs: [mac.identity.id])
        let sender = DirectTLS(credentials: mac, trustedIDs: [phone.identity.id])
        let listener = try makeListener(tls: receiver)
        defer { listener.close() }
        try await listener.start()
        let bytes = Data(repeating: 97, count: 132_700)
        let metadata = try ShareMetadata(filename: "Project Plan.md", project: "Test", sha256: ShareMetadata.digest(of: bytes))
        let offer = DirectOffer(id: UUID(), metadata: metadata, byteCount: bytes.count)
        let receives = Task {
            var persisted = false
            for await connection in listener.connections {
                let socket = listener.accept(connection, timeout: 4)
                defer { socket.close() }
                try await socket.start()
                XCTAssertEqual(try socket.peerID(), mac.identity.id)
                let invitation = try await socket.read(DirectControl.self)
                let offered = try XCTUnwrap(invitation.offer)
                XCTAssertEqual(offered.id, offer.id)
                if !persisted {
                    let (received, manifest) = try await DirectFileWire.fetch(offered, over: socket)
                    XCTAssertEqual(received, bytes)
                    XCTAssertEqual(manifest, metadata)
                    persisted = true
                    try await socket.write(DirectControl(.receipt, id: offered.id))
                } else {
                    try await socket.write(DirectControl(.receipt, id: offered.id))
                    return
                }
            }
        }
        defer { receives.cancel() }
        let first = try await connect(listener, tls: sender)
        defer { first.close() }
        XCTAssertEqual(try first.peerID(), phone.identity.id)
        var progress = [Int]()
        try await DirectFileWire.send(bytes, offer: offer, over: first) { progress.append($0) }
        XCTAssertEqual(progress.last, bytes.count)
        let retry = try await connect(listener, tls: sender)
        defer { retry.close() }
        try await DirectFileWire.send(bytes, offer: offer, over: retry) { _ in XCTFail("Duplicate offer re-sent the file") }
        try await receives.value
    }

    func testTLSRejectsImpersonationAndUnpairedClient() async throws {
        let mac = try credentials("Mac", platform: "macOS")
        let phone = try credentials("Phone", platform: "iOS")
        let impostor = try credentials("Phone", platform: "iOS")
        let listener = try makeListener(tls: DirectTLS(credentials: phone, trustedIDs: [mac.identity.id]))
        defer { listener.close() }
        try await listener.start()
        let server = Task {
            for await connection in listener.connections {
                let socket = listener.accept(connection, timeout: 4)
                defer { socket.close() }
                try? await socket.start()
            }
        }
        defer { server.cancel() }
        let validClientWrongPin = DirectTLS(credentials: mac, trustedIDs: [impostor.identity.id])
        let unpairedClient = DirectTLS(credentials: impostor, trustedIDs: [phone.identity.id])
        for tls in [validClientWrongPin, unpairedClient] {
            do {
                let socket = try await connect(listener, tls: tls)
                defer { socket.close() }
                try await DirectFileWire.ping(socket)
                XCTFail("Untrusted peer got an authenticated response")
            } catch {}
        }
    }

    func testNoReceiptAndInterruptedDownloadFail() async throws {
        let listener = try makeListener()
        defer { listener.close() }
        try await listener.start()
        let data = Data(repeating: 97, count: 130_000)
        let metadata = try ShareMetadata(filename: "test.md", sha256: ShareMetadata.digest(of: data))
        let offer = DirectOffer(id: UUID(), metadata: metadata, byteCount: data.count)
        let receiver = Task {
            for await connection in listener.connections {
                let socket = listener.accept(connection, timeout: 4)
                defer { socket.close() }
                try await socket.start()
                _ = try await socket.read(DirectControl.self)
                _ = try await DirectFileWire.fetch(offer, over: socket)
                return // Lost acknowledgment.
            }
        }
        defer { receiver.cancel() }
        let sender = try await connect(listener)
        defer { sender.close() }
        do {
            try await DirectFileWire.send(data, offer: offer, over: sender)
            XCTFail("Sender reported success before receipt")
        } catch {}
        try await receiver.value

        let interrupted = Task {
            for await connection in listener.connections {
                let socket = listener.accept(connection, timeout: 4)
                defer { socket.close() }
                try await socket.start()
                let request = try await socket.read(DirectControl.self)
                XCTAssertEqual(request.kind, .fetch)
                try await socket.send(Data(data.prefix(16)))
                return
            }
        }
        defer { interrupted.cancel() }
        let partialReceiver = try await connect(listener)
        defer { partialReceiver.close() }
        do {
            _ = try await DirectFileWire.fetch(offer, over: partialReceiver)
            XCTFail("An interrupted download passed integrity verification")
        } catch {}
        try await interrupted.value
    }

    private func credentials(_ name: String, platform: String) throws -> DeviceCredentials {
        try DeviceCredentials(name: name, platform: platform, privateKey: P256.Signing.PrivateKey())
    }

    private func makeListener(tls: DirectTLS? = nil) throws -> DirectListener {
        let parameters = LocalDiscovery.parameters(tls: tls?.options(), wifiOnly: false)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try DirectListener(parameters: parameters)
    }

    private func connect(_ listener: DirectListener, tls: DirectTLS? = nil) async throws -> DirectSocket {
        let port = try XCTUnwrap(listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: LocalDiscovery.parameters(tls: tls?.options(), wifiOnly: false))
        let socket = DirectSocket(connection: connection, timeout: 4)
        try await socket.start()
        return socket
    }
}

private final class TestTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: DirectIdentity?
    func record(_ identity: DirectIdentity) { lock.withLock { self.identity = identity } }
    var value: DirectIdentity? { lock.withLock { identity } }
}
