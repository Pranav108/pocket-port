import Foundation
import PocketPortProtocol
import XCTest
@testable import PocketPort

private actor TestTransport: ShareTransferring {
    enum Mode { case success, interrupted, wait }
    let mode: Mode
    let document: DownloadedFile
    private(set) var gets = 0
    private(set) var acks = 0

    init(document: DownloadedFile, mode: Mode) { self.document = document; self.mode = mode }

    func download(_ link: ShareLink) async throws -> DownloadedFile {
        gets += 1
        switch mode {
        case .success: return document
        case .interrupted: throw TransferError.incomplete
        case .wait: try await Task.sleep(nanoseconds: 60_000_000_000); return document
        }
    }
    func acknowledge(_ link: ShareLink) throws {
        acks += 1
        throw URLError(.timedOut)
    }
}

final class ImportTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private func fixture() throws -> DownloadedFile {
        let data = Data("# Plan\r\nCafé 📝\n".utf8)
        return try DownloadedFile(data: data, metadata: ShareMetadata(filename: "PLAN.md", project: "Work", sha256: ShareMetadata.digest(of: data)))
    }

    private func link() throws -> ShareLink {
        try ShareLink(host: "test.local", port: 8080, shareID: UUID(), token: ShareLink.generateToken(),
                      expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 180)
    }

    func testConcurrentCommitDistinctSharesAndOfflineRelaunch() async throws {
        let store = ImportStore(root: root)
        let document = try fixture()
        let firstID = UUID(), secondID = UUID()
        async let first = store.commit(document, shareID: firstID)
        async let duplicate = store.commit(document, shareID: firstID)
        let (saved, repeated) = try await (first, duplicate)
        XCTAssertEqual(saved, repeated)
        _ = try await store.commit(document, shareID: secondID)
        let abandoned = root.appendingPathComponent(".stage-orphan")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let damaged = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: false)
        let reopened = ImportStore(root: root)
        let records = try await reopened.list()
        XCTAssertEqual(Set(records.map(\.id)), [firstID, secondID])
        XCTAssertEqual(records.map(\.filename), ["PLAN.md", "PLAN.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        for record in records {
            let item = try await reopened.read(id: record.id)
            XCTAssertEqual(item.data, document.data)
        }
    }

    func testBinaryPreviewExportAndDeletionPreserveOriginalBytes() async throws {
        let store = ImportStore(root: root)
        let data = Data([0x89, 0x50, 0x4e, 0x47, 0xff])
        let metadata = try ShareMetadata(filename: "Original.PNG", sha256: ShareMetadata.digest(of: data))
        let id = UUID()
        _ = try await store.commit(DownloadedFile(data: data, metadata: metadata), shareID: id)
        let preview = try await store.preview(id: id)
        XCTAssertEqual(preview.url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: preview.url), data)
        let export = try await store.share(id: id)
        defer { try? FileManager.default.removeItem(at: export.url.deletingLastPathComponent()) }
        XCTAssertEqual(export.url.lastPathComponent, "Original.PNG")
        XCTAssertEqual(try Data(contentsOf: export.url), data)
        let secondID = UUID()
        _ = try await store.commit(try fixture(), shareID: secondID)
        try await store.delete(id: id)
        let remaining = try await store.list()
        XCTAssertEqual(remaining.map(\.id), [secondID])
        try await store.clear()
        let cleared = try await store.list()
        XCTAssertTrue(cleared.isEmpty)
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < limit else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testAmbiguousAckDoesNotUndoSaveAndRescanUsesStoredFile() async throws {
        let share = try link()
        let transport = TestTransport(document: try fixture(), mode: .success)
        let store = ImportStore(root: root)
        let model = ImportCoordinator(store: store, transfer: transport)
        model.scan(share.qrString)
        try await waitUntil { await transport.acks == 2 }
        guard case .committed(let saved) = model.phase else { return XCTFail("Expected committed") }
        model.reset()
        model.scan(share.qrString)
        try await waitUntil { await transport.acks == 4 }
        XCTAssertEqual(model.phase, .committed(saved))
        let count = await transport.gets
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testInterruptedAndCancelledDownloadsLeaveNoVisibleImportOrAck() async throws {
        for mode in [TestTransport.Mode.interrupted, .wait] {
            let store = ImportStore(root: root)
            let transport = TestTransport(document: try fixture(), mode: mode)
            let model = ImportCoordinator(store: store, transfer: transport)
            model.scan(try link().qrString)
            try await waitUntil { await transport.gets == 1 }
            if mode == .wait {
                model.reset()
                XCTAssertEqual(model.phase, .scanning)
            } else {
                try await waitUntil { model.phase == .failed(.transfer(.incomplete)) }
            }
            let records = try await store.list()
            let acks = await transport.acks
            XCTAssertTrue(records.isEmpty)
            XCTAssertEqual(acks, 0)
        }
    }

    @MainActor
    func testDiskFailurePreventsAck() async throws {
        try Data().write(to: root)
        let transport = TestTransport(document: try fixture(), mode: .success)
        let model = ImportCoordinator(store: ImportStore(root: root), transfer: transport)
        model.scan(try link().qrString)
        try await waitUntil { model.phase == .failed(.storage) }
        let count = await transport.acks
        XCTAssertEqual(count, 0)
    }
}

extension ImportTests {
    func testDirectRetryUsesPersistedImportAndRejectsConflictingOffer() async throws {
        let store = ImportStore(root: root)
        let file = try fixture()
        let offer = DirectOffer(id: UUID(), metadata: file.metadata, byteCount: file.data.count)
        let missing = try await store.existingDirect(offer, senderID: "first-mac")
        XCTAssertNil(missing)
        let first = try await store.commitDirect(file, offer: offer, senderID: "first-mac")
        let offline = ImportStore(root: root)
        let retry = try await offline.existingDirect(offer, senderID: "first-mac")
        XCTAssertEqual(retry, first)
        let second = try await offline.commitDirect(file, offer: offer, senderID: "second-mac")
        XCTAssertNotEqual(first.id, second.id)
        let conflicting = DirectOffer(id: offer.id, metadata: file.metadata, byteCount: file.data.count + 1)
        do {
            _ = try await offline.existingDirect(conflicting, senderID: "first-mac")
            XCTFail("Conflicting metadata was acknowledged")
        } catch DirectError.conflict {}
        let records = try await offline.list()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.format), [.markdown, .markdown])
    }

    func testDirectCorruptionIsNeverPersisted() async throws {
        let store = ImportStore(root: root)
        let file = try fixture()
        let offer = DirectOffer(id: UUID(), metadata: file.metadata, byteCount: file.data.count)
        let corrupted = DownloadedFile(data: Data(repeating: 65, count: file.data.count), metadata: file.metadata)
        do {
            _ = try await store.commitDirect(corrupted, offer: offer, senderID: "mac")
            XCTFail("Corrupted bytes were persisted")
        } catch DirectError.badMessage {}
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
    }
}
