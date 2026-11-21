import Foundation
import PocketPortProtocol
import XCTest
@testable import PocketPort

final class TransferClientTests: XCTestCase {
    func testBinaryDownloadPreservesOpaqueBytesAndMediaType() async throws {
        let client = TransferClient(protocolClasses: [FixtureURLProtocol.self])
        let download = try await client.download(try link(host: "binary.local"))
        XCTAssertEqual(download.data, FixtureURLProtocol.binary)
        XCTAssertEqual(download.metadata.filename, "report.pdf")
        XCTAssertEqual(download.metadata.format, .pdf)
    }

    func testCompleteDownloadPreservesOriginalBytesAndMetadata() async throws {
        let client = TransferClient(protocolClasses: [FixtureURLProtocol.self])
        let download = try await client.download(try link(host: "complete.local"))
        XCTAssertEqual(download.data, FixtureURLProtocol.original)
        XCTAssertEqual(download.metadata.filename, "PLAN.md")
        XCTAssertEqual(download.metadata.project, "Project One")
    }

    func testHTMLDownloadPreservesBytesAndFilenameAfterReopen() async throws {
        let client = TransferClient(protocolClasses: [FixtureURLProtocol.self])
        let share = try link(host: "html.local")
        let download = try await client.download(share)
        XCTAssertEqual(download.metadata.format, .html)
        XCTAssertEqual(download.data, FixtureURLProtocol.html)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ImportStore(root: root).commit(download, shareID: share.shareID)
        let reopened = try await ImportStore(root: root).read(id: share.shareID)
        XCTAssertEqual(reopened.record.filename, "Report.HTM")
        XCTAssertEqual(reopened.data, FixtureURLProtocol.html)
    }

    func testShortAndCorruptedResponsesFail() async throws {
        let client = TransferClient(protocolClasses: [FixtureURLProtocol.self])
        for host in ["truncated.local", "corrupted.local"] {
            do {
                _ = try await client.download(try link(host: host))
                XCTFail("Accepted an incomplete or corrupt response")
            } catch {
                XCTAssertEqual(error as? TransferError, .incomplete)
            }
        }
    }

    func testExpiredResponseUsesExpiryError() async throws {
        let client = TransferClient(protocolClasses: [FixtureURLProtocol.self])
        do {
            _ = try await client.download(try link(host: "expired.local"))
            XCTFail("Accepted an expired share")
        } catch {
            XCTAssertEqual(error as? TransferError, .expired)
        }
    }

    func testAcknowledgmentUsesPostWithBearerAndNoFragment() async throws {
        let client = TransferClient(protocolClasses: [FixtureURLProtocol.self])
        try await client.acknowledge(try link(host: "complete.local"))
    }

    func testHeaderValidationRejectsAmbiguousOrUnavailableLength() throws {
        let url = try XCTUnwrap(URL(string: "http://complete.local"))
        for length in [nil, "-1", "01", "3, 4", "5242881"] {
            var fields = FixtureURLProtocol.headers
            fields["Content-Length"] = length
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fields
            ))
            XCTAssertThrowsError(try TransferClient.validate(response)) {
                XCTAssertEqual($0 as? TransferError, .incomplete)
            }
        }
    }

    private func link(host: String) throws -> ShareLink {
        try ShareLink(
            host: host, port: 12345, shareID: UUID(), token: FixtureURLProtocol.token,
            expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 180
        )
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static let token = String(repeating: "A", count: 43)
    static let original = Data([0xef, 0xbb, 0xbf]) + Data("# One\r\n".utf8)
    static let binary = Data("%PDF-1.7\n".utf8) + Data([0xff, 0xfe])
    static let html = Data("<!doctype html><h1>Local HTML ✓</h1>\r\n".utf8)
    static let headers: [String: String] = [
        "Content-Type": ShareMetadata.contentType,
        "Content-Length": String(original.count),
        "X-ShareMD-Filename": "UExBTi5tZA",
        "X-ShareMD-Project": "UHJvamVjdCBPbmU",
        "X-ShareMD-SHA256": ShareMetadata.digest(of: original)
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.fragment == nil,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch (request.httpMethod, url.path.split(separator: "/").last, url.host) {
        case ("POST", "ack", "complete.local"):
            respond(status: 204)
        case ("GET", "file", "complete.local"):
            respond(status: 200, headers: Self.headers, data: Self.original)
        case ("GET", "file", "html.local"):
            do {
                let metadata = try ShareMetadata(filename: "Report.HTM", sha256: ShareMetadata.digest(of: Self.html))
                var headers = metadata.headers
                headers["Content-Type"] = "application/octet-stream"
                headers["Content-Length"] = String(Self.html.count)
                respond(status: 200, headers: headers, data: Self.html)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        case ("GET", "file", "binary.local"):
            do {
                let metadata = try ShareMetadata(filename: "report.pdf", sha256: ShareMetadata.digest(of: Self.binary))
                var headers = metadata.headers
                headers["Content-Type"] = "application/pdf"
                headers["Content-Length"] = String(Self.binary.count)
                respond(status: 200, headers: headers, data: Self.binary)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        case ("GET", "file", "truncated.local"):
            respond(status: 200, headers: Self.headers, data: Self.original.dropLast())
        case ("GET", "file", "corrupted.local"):
            respond(status: 200, headers: Self.headers, data: Data(repeating: 0x41, count: Self.original.count))
        case ("GET", "file", "expired.local"):
            respond(status: 410)
        default:
            respond(status: 404)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
