import Darwin
import XCTest
import PocketPortProtocol
@testable import PocketPortCLI

final class PocketPortCLITests: XCTestCase {
    func testBinarySnapshotPreservesBytesAndUsesMatchingContentType() throws {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = DispatchTime.now()
        let link = try ShareLink(host: "host.local", port: 1234, shareID: id,
                                 token: ShareLink.generateToken(), expiresAtUnixSeconds: 100)
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0xff])
        let file = directory.appendingPathComponent("Example.PNG")
        try bytes.write(to: file)
        let snapshot = try FileSnapshot.load(path: file.path, projectLabel: nil)
        var share = Session(link: link, snapshot: snapshot, deadline: now + 5)
        let reply = share.respond(Request(method: "GET", path: link.downloadURL.path,
                                          authorization: link.authorizationHeader), now: now)
        XCTAssertEqual(reply.headers["Content-Type"], "image/png")
        XCTAssertEqual(reply.bytes, bytes)
    }

    func testSnapshotAndSession() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data([0xef, 0xbb, 0xbf, 65, 13, 10])
        for folder in ["One", "Two"] {
            let dir = base.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Plan.MD")
            try bytes.write(to: url)
            let snapshot = try FileSnapshot.load(path: url.path, projectLabel: nil)
            XCTAssertEqual(snapshot.metadata.project, folder)
            try Data("changed".utf8).write(to: url)
            let link = try ShareLink(host: "host.local", port: 123, shareID: UUID(), token: ShareLink.generateToken(), expiresAtUnixSeconds: 100)
            let now = DispatchTime.now()
            var session = Session(link: link, snapshot: snapshot, deadline: now + 2)
            let get = Request(method: "GET", path: link.downloadURL.path, authorization: link.authorizationHeader)
            let ack = Request(method: "POST", path: link.acknowledgmentURL.path, authorization: link.authorizationHeader)
            XCTAssertEqual(session.respond(Request(method: "GET", path: "/wrong", authorization: link.authorizationHeader), now: now).status, 404)
            XCTAssertEqual(session.respond(Request(method: "GET", path: get.path, authorization: "bad"), now: now).status, 404)
            XCTAssertEqual(session.respond(get, now: now).bytes, bytes)
            XCTAssertEqual(session.respond(get, now: now).bytes, bytes)
            var expired = session
            XCTAssertEqual(expired.respond(ack, now: now + 2).status, 410)
            XCTAssertEqual(expired.respond(get, now: now + 2).status, 410)
            XCTAssertEqual(session.respond(ack, now: now).status, 204)
            XCTAssertNil(session.snapshot)
            XCTAssertEqual(session.respond(get, now: now).status, 410)
            XCTAssertEqual(session.respond(ack, now: now).status, 204)
        }
    }
    func testHeaders() throws {
        let prefix = "POST /test HTTP/1.1\r\nHost: host.local\r\n"
        XCTAssertNil(try Request.parse(Data(prefix.utf8)))
        XCTAssertEqual(try Request.parse(Data((prefix + "Content-Length: 0\r\n\r\n").utf8))?.path, "/test")
        for suffix in ["Content-Length: 1\r\n\r\n", "Transfer-Encoding: chunked\r\n\r\n", "Host: second\r\n\r\n", "\r\nbody", " Authorization: fake\r\n\r\n"] {
            XCTAssertThrowsError(try Request.parse(Data((prefix + suffix).utf8)))
        }
        XCTAssertThrowsError(try Request.parse(Data(repeating: 65, count: Request.maximumBytes + 1)))
    }
    func testArgumentsAndQR() throws {
        XCTAssertNil(try Arguments([]).path)
        XCTAssertEqual(try Arguments(["--project", "Test", "--", "-abc.md"]).path, "-abc.md")
        XCTAssertThrowsError(try Arguments(["--project"]))
        XCTAssertThrowsError(try TerminalQR.render("test", columns: 10))
        let qr = try TerminalQR.render("test", columns: 80)
        let rows = qr.components(separatedBy: "\n").map {
            Array($0.replacingOccurrences(of: "\u{1b}[0;30;47m", with: "").replacingOccurrences(of: "\u{1b}[0m", with: ""))
        }
        func black(_ x: Int, _ y: Int) -> Bool {
            let module = rows[y / 2][x]
            return module == "█" || module == (y.isMultiple(of: 2) ? "▀" : "▄")
        }
        // Validate all three finder patterns in terminal coordinates.
        let far = rows[0].count - 11
        for (originX, originY) in [(4, 4), (far, 4), (4, far)] {
            for y in 0..<7 {
                for x in 0..<7 {
                    XCTAssertEqual(black(originX + x, originY + y),
                        x == 0 || x == 6 || y == 0 || y == 6 || (2...4).contains(x) && (2...4).contains(y))
                }
            }
        }
    }
    func testAutomaticSelectionRequiresExactlyOneShareableFileInCurrentFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("Notes".utf8).write(to: nested.appendingPathComponent("notes.txt"))
        try Data().write(to: root.appendingPathComponent("archive.zip"))
        try Data([0xff]).write(to: root.appendingPathComponent("invalid.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.pdf"),
                                                withIntermediateDirectories: false)

        XCTAssertThrowsError(try FileSnapshot.loadOnlyShareableFile(in: root, projectLabel: nil)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("No shareable files in this folder."))
        }

        let image = Data([0x89, 0x50, 0x4e, 0x47])
        try image.write(to: root.appendingPathComponent("Photo.PNG"))
        let snapshot = try FileSnapshot.loadOnlyShareableFile(in: root, projectLabel: "Trip")
        XCTAssertEqual(snapshot.metadata.filename, "Photo.PNG")
        XCTAssertEqual(snapshot.metadata.project, "Trip")
        XCTAssertEqual(snapshot.bytes, image)

        try Data("# Plan".utf8).write(to: root.appendingPathComponent("plan.md"))
        XCTAssertThrowsError(try FileSnapshot.loadOnlyShareableFile(in: root, projectLabel: nil)) { error in
            XCTAssertEqual(error.localizedDescription, "Multiple shareable files in this folder. Run pocket-port <filename>.")
        }
    }

    func testUnsupportedFileErrorListsOnlySupportedExtensions() throws {
        XCTAssertThrowsError(try FileSnapshot.load(path: "example.zip", projectLabel: nil)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Unsupported file type. Supported extensions: .bmp, .gif, .heic, .heif, .htm, .html, .jpeg, .jpg, .markdown, .md, .pdf, .png, .tif, .tiff, .txt, .webp.")
        }
    }

    func testHTMLSnapshotIsSharedAsAnAttachment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("<!doctype html><h1>Quarterly review ✓</h1>".utf8)
        let now = DispatchTime.now()
        let link = try ShareLink(host: "host.local", port: 1234, shareID: UUID(),
                                 token: ShareLink.generateToken(), expiresAtUnixSeconds: 100)
        for filename in ["Report.HTML", "Report.htm"] {
            let file = folder.appendingPathComponent(filename)
            try bytes.write(to: file)
            let snapshot = try FileSnapshot.loadOnlyShareableFile(in: folder, projectLabel: nil)
            XCTAssertEqual(snapshot.metadata.filename, filename)
            XCTAssertEqual(snapshot.metadata.format, .html)
            var session = Session(link: link, snapshot: snapshot, deadline: now + 5)
            let response = session.respond(Request(method: "GET", path: link.downloadURL.path,
                                                   authorization: link.authorizationHeader), now: now)
            XCTAssertEqual(response.bytes, bytes)
            XCTAssertEqual(response.headers["Content-Type"], "application/octet-stream")
            XCTAssertEqual(response.headers["Content-Disposition"], "attachment")
            XCTAssertEqual(response.headers["X-Content-Type-Options"], "nosniff")
            try FileManager.default.removeItem(at: file)
        }
    }
    func testSourceValidationAndSymlinkName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("target")
        let link = dir.appendingPathComponent("selected.Markdown")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try Data().write(to: source)
        let empty = try FileSnapshot.load(path: link.path, projectLabel: "override")
        XCTAssertEqual(empty.metadata.filename, link.lastPathComponent)
        XCTAssertEqual(empty.metadata.project, "override")
        XCTAssertTrue(empty.bytes.isEmpty)
        try Data([0xff]).write(to: source)
        XCTAssertThrowsError(try FileSnapshot.load(path: link.path, projectLabel: nil))
        try Data(repeating: 65, count: ShareMetadata.maximumFileBytes + 1).write(to: source)
        XCTAssertThrowsError(try FileSnapshot.load(path: link.path, projectLabel: nil))
        let fifo = dir.appendingPathComponent("pipe.md")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try FileSnapshot.load(path: fifo.path, projectLabel: nil))
    }

    func testPowerAssertionReleased() throws {
        func assertions() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let ownPID = "pid \(ProcessInfo.processInfo.processIdentifier)("
        func hasAssertion() throws -> Bool {
            try assertions().components(separatedBy: "\n").contains { $0.contains(ownPID) && $0.contains("PocketPort active file transfer") }
        }
        var assertion: PowerAssertion? = try PowerAssertion()
        try withExtendedLifetime(assertion) { XCTAssertTrue(try hasAssertion()) }
        assertion = nil
        XCTAssertFalse(try hasAssertion())
    }

    func testLiveDualStackDownloadAndAcknowledgment() async throws {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let bindError = errno
        close(probe)
        if result < 0 && (bindError == EPERM || bindError == EACCES) {
            throw XCTSkip("Execution sandbox denies binding a loopback test listener.")
        }
        XCTAssertEqual(result, 0)
        let bytes = Data(repeating: 65, count: ShareMetadata.maximumFileBytes)
        let snapshot = FileSnapshot(bytes: bytes, metadata: try ShareMetadata(filename: "plan.md", sha256: ShareMetadata.digest(of: bytes)))
        let server = try ShareServer(host: "test.local", snapshot: snapshot)
        let ready = expectation(description: "Listener ready")
        let stopped = expectation(description: "ACK releases listener")
        var active: ShareLink?
        server.onReady = { active = $0; ready.fulfill() }
        server.onStop = { _, code in XCTAssertEqual(code, 0); stopped.fulfill() }
        server.start()
        defer { server.requestStop() }
        await fulfillment(of: [ready], timeout: 5)
        let link = try XCTUnwrap(active)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func fetch(_ host: String, ack: Bool) async throws -> (Data, Int?) {
            let path = ack ? link.acknowledgmentURL.path : link.downloadURL.path
            var request = URLRequest(url: URL(string: "http://\(host):\(link.port)\(path)")!)
            request.httpMethod = ack ? "POST" : "GET"
            request.setValue(link.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 4
            let (data, response) = try await client.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode)
        }
        // Read a prefix, then reset the TCP socket before retrying the same share.
        try disconnectDuringGET(link)
        for host in ["127.0.0.1", "[::1]"] {
            let response = try await fetch(host, ack: false)
            XCTAssertEqual(response.0, bytes)
            XCTAssertEqual(response.1, 200)
        }
        let response = try await fetch("127.0.0.1", ack: true)
        XCTAssertEqual(response.1, 204)
        await fulfillment(of: [stopped], timeout: 2)
    }

    private func disconnectDuringGET(_ link: ShareLink) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("Cannot create client socket.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        var reset = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))), 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout.size(ofValue: reset))), 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(link.port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw CLIError("Cannot connect client socket.") }
        let query = Data("GET \(link.downloadURL.path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: \(link.authorizationHeader)\r\n\r\n".utf8)
        let written = query.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, query.count)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < 8192 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw CLIError("Transfer ended before interruption.") }
            received.append(contentsOf: buffer.prefix(count))
            if let end = received.range(of: Data("\r\n\r\n".utf8)), received.endIndex > end.upperBound {
                XCTAssertEqual(received[end.upperBound], 65)
                return
            }
        }
        XCTFail("No body prefix received.")
    }
}

extension PocketPortCLITests {
    func testDirectArgumentsAndLegacyInvocation() throws {
        XCTAssertNil(try DirectCommand.parse(["--project", "A", "README.md"]))
        XCTAssertNil(try DirectCommand.parse([]))
        XCTAssertEqual(try DirectCommand.parse(["pair", "--alias", "Phone"]), .pair("phone"))
        XCTAssertEqual(try DirectCommand.parse(["send", "notes/My file.md", "-t", "iphone,ipad"]),
                       .send(file: "notes/My file.md", target: "iphone,ipad", project: nil))
        XCTAssertEqual(try DirectCommand.parse(["send", "-t", "all"]), .send(file: nil, target: "all", project: nil))
        XCTAssertEqual(try DirectCommand.parse(["send", "--", "-draft.html"]),
                       .send(file: "-draft.html", target: nil, project: nil))
        XCTAssertThrowsError(try DirectCommand.parse(["send", "-t"]))
        XCTAssertThrowsError(try DirectCommand.parse(["send", "-t", "iphone", "--to", "ipad"]))
        XCTAssertThrowsError(try DirectCommand.parse(["pair", "--alias", "all"]))
    }
}
