import Foundation
import PocketPortProtocol

struct ImportRecord: Codable, Identifiable, Hashable, Sendable {
    let version: Int
    let id: UUID
    let filename: String
    let project: String?
    let importedAt: Date
    let byteCount: Int
    let sha256: String

    var format: ShareFileFormat? { ShareFileFormat(filename: filename) }
}

struct SharedFile: Identifiable, Sendable {
    let id: UUID
    let url: URL
}

actor ImportStore {
    private let root: URL
    private let files = FileManager.default
    private var prepared = false

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imports", isDirectory: true)
    }

    private func prepare() throws {
        guard !prepared else { return }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".stage-") {
            try? files.removeItem(at: entry)
        }
        prepared = true
    }

    private func storedFile(id: UUID) throws -> (record: ImportRecord, url: URL) {
        try prepare()
        let directory = root.appendingPathComponent(id.uuidString)
        let metadata = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        let record = try JSONDecoder().decode(ImportRecord.self, from: metadata)
        guard let format = record.format else { throw CocoaError(.fileReadCorruptFile) }
        _ = try ShareMetadata(filename: record.filename, sha256: record.sha256)
        let document = directory.appendingPathComponent(format.storedFilename(original: record.filename))
        let size = try document.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard record.version == 1, record.id == id, (0...format.maximumByteCount).contains(record.byteCount),
              size == record.byteCount else { throw CocoaError(.fileReadCorruptFile) }
        return (record, document)
    }

    func read(id: UUID) throws -> (record: ImportRecord, data: Data) {
        let (record, document) = try storedFile(id: id)
        let data = try Data(contentsOf: document, options: [.mappedIfSafe])
        guard data.count == record.byteCount, ShareMetadata.digest(of: data) == record.sha256,
              record.format?.requiresUTF8 != true || String(data: data, encoding: .utf8) != nil
        else { throw CocoaError(.fileReadCorruptFile) }
        return (record, data)
    }

    func preview(id: UUID) throws -> (record: ImportRecord, url: URL) {
        _ = try read(id: id)
        return try storedFile(id: id)
    }

    func list() throws -> [ImportRecord] {
        try prepare()
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? storedFile(id: $0).record }
            .sorted { lhs, rhs in
                lhs.importedAt == rhs.importedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.importedAt > rhs.importedAt
            }
    }

    func existing(id: UUID) throws -> ImportRecord? {
        try prepare()
        guard files.fileExists(atPath: root.appendingPathComponent(id.uuidString).path) else { return nil }
        return try read(id: id).record
    }

    func commit(_ download: DownloadedFile, shareID: UUID) throws -> ImportRecord {
        try Task.checkCancellation()
        if let record = try existing(id: shareID) { return record }
        guard let format = download.metadata.format,
              download.data.count <= format.maximumByteCount else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        let record = ImportRecord(version: 1, id: shareID, filename: download.metadata.filename,
                                  project: download.metadata.project, importedAt: Date(),
                                  byteCount: download.data.count, sha256: download.metadata.sha256)
        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        try download.data.write(to: stage.appendingPathComponent(format.storedFilename(original: record.filename)))
        try JSONEncoder().encode(record).write(to: stage.appendingPathComponent("metadata.json"))
        try Task.checkCancellation()
        try files.moveItem(at: stage, to: root.appendingPathComponent(shareID.uuidString))
        return record
    }

    func existingDirect(_ offer: DirectOffer, senderID: String) throws -> ImportRecord? {
        let id = offer.importID(senderID: senderID)
        guard let record = try existing(id: id) else { return nil }
        guard record.filename == offer.filename, record.project == offer.project,
              record.sha256 == offer.sha256, record.byteCount == offer.byteCount else { throw DirectError.conflict }
        return record
    }

    func commitDirect(_ download: DownloadedFile, offer: DirectOffer, senderID: String) throws -> ImportRecord {
        if let record = try existingDirect(offer, senderID: senderID) { return record }
        let metadata = try offer.validate()
        guard download.metadata == metadata, download.data.count == offer.byteCount else { throw DirectError.badMessage }
        try DirectFileWire.validate(download.data, against: metadata)
        return try commit(download, shareID: offer.importID(senderID: senderID))
    }

    func share(id: UUID) throws -> SharedFile {
        let item = try preview(id: id)
        let exportID = UUID()
        let directory = files.temporaryDirectory.appendingPathComponent("PocketPort-\(exportID.uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(item.record.filename)
        do {
            try files.copyItem(at: item.url, to: destination)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        return SharedFile(id: exportID, url: destination)
    }

    func delete(id: UUID) throws {
        try prepare()
        let directory = root.appendingPathComponent(id.uuidString)
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
    }

    func clear() throws {
        try prepare()
        for directory in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where UUID(uuidString: directory.lastPathComponent) != nil {
            try files.removeItem(at: directory)
        }
    }
}
