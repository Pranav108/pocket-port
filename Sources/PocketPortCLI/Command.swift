import Darwin
import Foundation
import IOKit.pwr_mgt
import PocketPortProtocol
import SystemConfiguration

struct Arguments {
    static let help = """
    Usage: pocket-port [--project <label>] [--] [file]
    Run without a file to share the only eligible file in this folder.
    If this folder has several eligible files, pass a filename or path.
    Share Markdown, text, HTML, PDFs, and images on the same trusted Wi-Fi.
    The QR expires in three minutes. Keep the Mac lid open during sharing.
    """
    var path: String?
    var project: String?
    var help = false
    init(_ values: [String]) throws {
        var options = true
        var iterator = values.makeIterator()
        while let arg = iterator.next() {
            if options && arg == "--" { options = false }
            else if options && ["--help", "-h"].contains(arg) { help = true; return }
            else if options && arg == "--project" {
                guard project == nil, let label = iterator.next() else { throw CLIError("Supply one --project label.") }
                guard label.utf8.count <= ShareMetadata.maximumProjectBytes else {
                    throw CLIError("Project labels must be at most \(ShareMetadata.maximumProjectBytes) UTF-8 bytes.")
                }
                project = label
            } else {
                guard path == nil, !options || !arg.hasPrefix("-") else { throw CLIError(Self.help) }
                path = arg
            }
        }
    }
}

final class PowerAssertion {
    private var id = IOPMAssertionID(0)
    init() throws {
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "PocketPort active file transfer" as CFString, &id)
        guard result == kIOReturnSuccess else { throw CLIError("Cannot keep the Mac awake for this share.") }
    }
    deinit { IOPMAssertionRelease(id) }
}

@main
enum Command {
    static func displayText(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "�" : String($0) }.joined())
    }
    static func makeServer(snapshot: FileSnapshot) throws -> ShareServer {
        let columns = try TerminalQR.columns()
        guard let local = SCDynamicStoreCopyLocalHostName(nil) as String? else {
            throw CLIError("Cannot determine the Mac’s Bonjour local hostname.")
        }
        let host = local + ".local"
        let expiry = Int64(Date().timeIntervalSince1970) + ShareLink.lifetimeSeconds
        guard let preview = try? ShareLink(host: host, port: 65535, shareID: UUID(),
            token: ShareLink.generateToken(), expiresAtUnixSeconds: expiry) else {
            throw CLIError("The Mac’s Bonjour local hostname is unusable.")
        }
        _ = try TerminalQR.render(preview.qrString, columns: columns)
        let server: ShareServer
        do { server = try ShareServer(host: host, snapshot: snapshot, shareID: preview.shareID, token: preview.token) }
        catch { throw CLIError("Cannot create listener: \(error.localizedDescription)") }
        let metadata = snapshot.metadata
        var assertion: PowerAssertion?
        server.onReady = { link in
            let qr = try TerminalQR.render(link.qrString, columns: columns)
            assertion = try PowerAssertion()
            print("Sharing \(displayText(metadata.filename))")
            if let project = metadata.project { print("Project: \(displayText(project))") }
            print("Expires at \(Date(timeIntervalSince1970: TimeInterval(link.expiresAtUnixSeconds)).formatted()). Keep the lid open. Press Ctrl-C to stop.")
            print(qr)
            fflush(stdout)
        }
        server.onStop = { message, code in
            withExtendedLifetime(assertion) {}
            assertion = nil
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(code)
        }
        return server
    }
    static func main() {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if args.help { print(Arguments.help); return }
            let snapshot: FileSnapshot
            if let path = args.path {
                snapshot = try FileSnapshot.load(path: path, projectLabel: args.project)
            } else {
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                snapshot = try FileSnapshot.loadOnlyShareableFile(in: directory, projectLabel: args.project)
            }
            let server = try makeServer(snapshot: snapshot)
            let sources = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: server.queue)
                source.setEventHandler { server.stop("Share stopped.", code: 128 + number) }
                source.resume()
                return source
            }
            server.start()
            withExtendedLifetime((server, sources)) { dispatchMain() }
        } catch {
            FileHandle.standardError.write(Data(("pocket-port: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
