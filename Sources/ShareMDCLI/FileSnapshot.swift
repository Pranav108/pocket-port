import Darwin
import Foundation
import ShareProtocol

struct CLIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct FileSnapshot {
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    let bytes: Data
    let metadata: ShareMetadata

    static func load(path: String, projectLabel: String?) throws -> Self {
        let url = URL(fileURLWithPath: path)
        guard markdownExtensions.contains(url.pathExtension.lowercased()) || url.lastPathComponent.lowercased() == "readme" else {
            throw CLIError("Choose a README, .md, or .markdown file.")
        }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CLIError("Cannot open the selected file: \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CLIError("Choose a readable regular file.")
        }
        let limit = ShareMetadata.maximumFileBytes
        guard info.st_size <= limit else { throw CLIError("File exceeds 5 MiB.") }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, min(buffer.count, limit + 1 - bytes.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CLIError("Cannot read the selected file.") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= limit else { throw CLIError("File exceeds 5 MiB.") }
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw CLIError("File requires UTF-8 encoding.") }
        let parent = url.deletingLastPathComponent().standardizedFileURL.lastPathComponent
        do {
            let metadata = try ShareMetadata(filename: url.lastPathComponent, project: projectLabel ?? (parent == "/" ? nil : parent), sha256: ShareMetadata.digest(of: bytes))
            return Self(bytes: bytes, metadata: metadata)
        } catch { throw CLIError("Filename or project label exceeds the supported metadata format.") }
    }
}
