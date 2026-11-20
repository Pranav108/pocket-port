import CryptoKit
import Foundation

public struct ShareMetadata: Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidFilename
        case invalidProject
        case invalidDigest
        case duplicateHeader
    }

    public static let filenameHeader = "X-ShareMD-Filename"
    public static let projectHeader = "X-ShareMD-Project"
    public static let digestHeader = "X-ShareMD-SHA256"
    public static let contentType = "text/markdown; charset=utf-8"
    public static let maximumFilenameBytes = 1024
    public static let maximumProjectBytes = 256
    public static let maximumFileBytes = 5 * 1024 * 1024

    public let filename: String
    public let project: String?
    public let sha256: String

    public init(filename: String, project: String? = nil, sha256: String) throws {
        guard !filename.isEmpty,
              filename.utf8.prefix(Self.maximumFilenameBytes + 1).count <= Self.maximumFilenameBytes,
              filename != ".", filename != "..",
              !filename.utf8.contains(where: { $0 == 0 || $0 == 47 || $0 == 92 }) else {
            throw ValidationError.invalidFilename
        }
        if let project,
           project.utf8.prefix(Self.maximumProjectBytes + 1).count > Self.maximumProjectBytes {
            throw ValidationError.invalidProject
        }
        guard sha256.utf8.prefix(65).count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ValidationError.invalidDigest
        }
        self.filename = filename
        self.project = project
        self.sha256 = sha256
    }

    public init(headers: [String: String]) throws {
        let recognizedNames = [Self.filenameHeader, Self.projectHeader, Self.digestHeader].map { $0.lowercased() }
        var recognizedHeaders: [String: String] = [:]
        for (key, value) in headers {
            let name = key.lowercased()
            guard recognizedNames.contains(name) else {
                continue
            }
            guard recognizedHeaders.updateValue(value, forKey: name) == nil else {
                throw ValidationError.duplicateHeader
            }
        }

        guard let encodedFilename = recognizedHeaders[Self.filenameHeader.lowercased()],
              let filename = Self.decodeText(encodedFilename, maximumByteCount: Self.maximumFilenameBytes) else {
            throw ValidationError.invalidFilename
        }
        let project: String?
        if let encodedProject = recognizedHeaders[Self.projectHeader.lowercased()] {
            guard let decodedProject = Self.decodeText(encodedProject, maximumByteCount: Self.maximumProjectBytes) else {
                throw ValidationError.invalidProject
            }
            project = decodedProject
        } else {
            project = nil
        }
        guard let sha256 = recognizedHeaders[Self.digestHeader.lowercased()] else {
            throw ValidationError.invalidDigest
        }

        try self.init(filename: filename, project: project, sha256: sha256)
    }

    public var headers: [String: String] {
        var headers = [
            Self.filenameHeader: Base64URL.encode(Data(filename.utf8)),
            Self.digestHeader: sha256,
        ]
        if let project {
            headers[Self.projectHeader] = Base64URL.encode(Data(project.utf8))
        }
        return headers
    }

    public static func digest(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeText(_ value: String, maximumByteCount: Int) -> String? {
        guard let bytes = Base64URL.decode(value, maximumByteCount: maximumByteCount) else {
            return nil
        }
        // Decode as text while preserving an initial U+FEFF as part of the field.
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}
