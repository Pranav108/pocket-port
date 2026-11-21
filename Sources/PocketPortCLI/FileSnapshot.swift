import Darwin
import Foundation
import PocketPortProtocol

struct CLIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct FileSnapshot {
    static let supportedExtensionsMessage = "Supported extensions: " +
        ShareFileFormat.supportedExtensions.map { "." + $0 }.joined(separator: ", ") + "."

    let bytes: Data
    let metadata: ShareMetadata

    static func loadOnlyShareableFile(in directory: URL, projectLabel: String?) throws -> Self {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var selected: Self?
        for url in entries where ShareFileFormat(filename: url.lastPathComponent) != nil {
            guard let snapshot = try? load(path: url.path, projectLabel: projectLabel) else { continue }
            guard selected == nil else {
                throw CLIError("Multiple shareable files in this folder. Run pocket-port <filename>.")
            }
            selected = snapshot
        }
        guard let selected else {
            throw CLIError("No shareable files in this folder. " + supportedExtensionsMessage)
        }
        return selected
    }

    static func load(path: String, projectLabel: String?) throws -> Self {
        let url = URL(fileURLWithPath: path)
        guard let format = ShareFileFormat(filename: url.lastPathComponent) else {
            throw CLIError("Unsupported file type. " + supportedExtensionsMessage)
        }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CLIError("Cannot open the selected file: \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CLIError("Choose a readable regular file.")
        }
        let limit = format.maximumByteCount
        let limitError = CLIError("File exceeds \(limit / 1024 / 1024) MiB.")
        guard info.st_size <= limit else { throw limitError }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, min(buffer.count, limit + 1 - bytes.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CLIError("Cannot read the selected file.") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= limit else { throw limitError }
        }
        if format.requiresUTF8, String(bytes: bytes, encoding: .utf8) == nil {
            throw CLIError("Markdown, text, and HTML files require UTF-8 encoding.")
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL.lastPathComponent
        do {
            let metadata = try ShareMetadata(filename: url.lastPathComponent, project: projectLabel ?? (parent == "/" ? nil : parent), sha256: ShareMetadata.digest(of: bytes))
            return Self(bytes: bytes, metadata: metadata)
        } catch { throw CLIError("Filename or project label exceeds the supported metadata format.") }
    }
}
