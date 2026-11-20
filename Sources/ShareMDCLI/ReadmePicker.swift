import Darwin
import Foundation

enum ReadmePicker {
    static func candidates(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = FileManager.default.enumerator(atPath: directory.path) else {
            throw CLIError("Cannot search the current folder for README files.")
        }

        var matches: [URL] = []
        for case let path as String in entries {
            let url = directory.appendingPathComponent(path)
            if url.lastPathComponent == ".git" {
                entries.skipDescendants()
                continue
            }

            guard isReadme(url), let values = try? url.resourceValues(forKeys: keys) else { continue }
            let isRegularFile = values.isRegularFile == true || (
                values.isSymbolicLink == true &&
                (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            )
            if isRegularFile { matches.append(url) }
        }

        return matches.sorted {
            let lhs = $0.pathComponents.count
            let rhs = $1.pathComponents.count
            if lhs != rhs { return lhs < rhs }
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    static func choose(in directory: URL) throws -> URL? {
        let files = try candidates(in: directory)
        guard let first = files.first else {
            throw CLIError("No README files found in this folder or its subfolders. You can pass a Markdown file path to share it directly.")
        }
        if files.count == 1 { return first }
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw CLIError("Choose a README in an interactive terminal or pass its file path to share-md.")
        }

        for (index, url) in files.enumerated() {
            let relativePath = url.pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")
            print("  \(index + 1). \(Command.displayText(relativePath))")
        }

        while true {
            print("Choose a README by number, or q to quit: ", terminator: "")
            fflush(stdout)
            guard let selection = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  selection.lowercased() != "q" else { return nil }
            if let number = Int(selection), (1...files.count).contains(number) {
                return files[number - 1]
            }
            print("Enter a number from 1 to \(files.count).")
        }
    }

    private static func isReadme(_ url: URL) -> Bool {
        if url.lastPathComponent.lowercased() == "readme" { return true }
        guard FileSnapshot.markdownExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return stem == "readme" || stem.hasPrefix("readme.") || stem.hasPrefix("readme-") || stem.hasPrefix("readme_")
    }
}
