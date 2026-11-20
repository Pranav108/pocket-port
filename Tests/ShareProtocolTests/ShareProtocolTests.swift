import Foundation
import ShareProtocol
import XCTest

final class ShareProtocolTests: XCTestCase {
    private struct WireExample: Decodable {
        let qrString: String
        let downloadURL: String
        let acknowledgmentURL: String
        let authorizationHeader: String
        let bodyBase64: String
        let headers: [String: String]
    }

    private func wireExample() throws -> WireExample {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "wire-v1", withExtension: "json"))
        return try JSONDecoder().decode(WireExample.self, from: Data(contentsOf: fixture))
    }

    func testWireExampleRoundTrip() throws {
        let example = try wireExample()
        let link = try ShareLink(scannedValue: example.qrString)
        XCTAssertEqual(link.qrString, example.qrString)
        XCTAssertEqual(link.downloadURL.absoluteString, example.downloadURL)
        XCTAssertEqual(link.acknowledgmentURL.absoluteString, example.acknowledgmentURL)
        XCTAssertNil(link.downloadURL.fragment)
        XCTAssertNil(link.acknowledgmentURL.fragment)
        XCTAssertEqual(link.authorizationHeader, example.authorizationHeader)
        XCTAssertTrue(link.matchesAuthorizationHeader(example.authorizationHeader))
        XCTAssertFalse(String(reflecting: link).contains(link.token))

        let metadata = try ShareMetadata(headers: example.headers)
        XCTAssertEqual(metadata.filename, "résumé.md")
        XCTAssertEqual(metadata.project, "計画 📓")
        XCTAssertEqual(example.headers["Content-Type"], ShareMetadata.contentType)
        XCTAssertEqual(example.headers["Cache-Control"], "no-store")
        let body = try XCTUnwrap(Data(base64Encoded: example.bodyBase64))
        XCTAssertEqual(body, Data([0xEF, 0xBB, 0xBF]) + Data("# Share.md\r\nhello\r\n".utf8))
        XCTAssertEqual(example.headers["Content-Length"], String(body.count))
        XCTAssertEqual(ShareMetadata.digest(of: body), metadata.sha256)
        XCTAssertEqual(metadata, try ShareMetadata(headers: metadata.headers))
    }

    func testMalformedAndHostileLinks() throws {
        let example = try wireExample()
        let link = try ShareLink(scannedValue: example.qrString)
        let options: [(String, String)] = [
            ("http://", "https://"),
            ("http://", "HTTP://"),
            ("pranavs-mac.local", "a.b.local"),
            ("pranavs-mac.local", "a_local.local"),
            ("pranavs-mac.local", "-a.local"),
            ("pranavs-mac.local", "a-.local"),
            ("pranavs-mac.local", "m\u{E4}c.local"),
            ("pranavs-mac.local", "%61.local"),
            ("pranavs-mac.local", "pranavs-mac.local."),
            ("pranavs-mac.local", "user:pass@pranavs-mac.local"),
            ("pranavs-mac.local", "user@pranavs-mac.local"),
            ("pranavs-mac.local", "127.0.0.1"),
            ("pranavs-mac.local", "[::1]"),
            ("pranavs-mac.local", String(repeating: "a", count: 64) + ".local"),
            (":49152", ""),
            (":49152", ":0"),
            (":49152", ":65536"),
            (":49152", ":049152"),
            (":49152", ":+49152"),
            ("share-md", "share%2Dmd"),
            ("/v1/", "/v2/"),
            ("/v1/", "//v1/"),
            ("aabbccddeeff", "AABBCCDDEEFF"),
            ("aabbccddeeff", "aabbccddeefg"),
            ("/file#", "/file/#"),
            ("/file#", "/file?query=x#"),
            ("/file#", "/file?#"),
            ("/file#", "/ack#"),
            ("token=", "TOKEN="),
            (link.token, link.token + "="),
            (link.token, String(link.token.dropLast()) + "9"),
            (link.token, String(link.token.dropFirst())),
            ("&expires=", "&unknown="),
            ("&expires=", "&token="),
            ("2000000000", "0"),
            ("2000000000", "-1"),
            ("2000000000", "02000000000"),
            ("2000000000", "+2000000000"),
            ("2000000000", "9223372036854775808"),
            ("2000000000", "2000000000&expires=2000000000"),
        ]
        for (original, replacement) in options {
            let malformed = example.qrString.replacingOccurrences(of: original, with: replacement)
            XCTAssertThrowsError(try ShareLink(scannedValue: malformed), "Accepted mutation of \(original)")
        }
        XCTAssertThrowsError(try ShareLink(scannedValue: example.qrString + "#extra"))
        XCTAssertThrowsError(try ShareLink(scannedValue: example.qrString + "\n"))
        XCTAssertThrowsError(try ShareLink(scannedValue: example.qrString + String(repeating: "a", count: 512)))
        let reverse = example.downloadURL + "#expires=2000000000&token=" + link.token
        XCTAssertThrowsError(try ShareLink(scannedValue: reverse))
    }

    func testExplicitPortAndCaseInsensitiveDNS() throws {
        let example = try wireExample()
        for port in [1, 80, 65535] {
            let scanned = example.qrString.replacingOccurrences(of: "pranavs-mac.local:49152", with: "Device.LOCAL:\(port)")
            let link = try ShareLink(scannedValue: scanned)
            XCTAssertEqual(link.host, "device.local")
            XCTAssertEqual(link.port, port)
            XCTAssertEqual(link.downloadURL.port, port)
            XCTAssertEqual(link, try ShareLink(scannedValue: link.qrString))
        }
    }

    func testAuthorizationAndGeneratedToken() throws {
        let example = try wireExample()
        let link = try ShareLink(scannedValue: example.qrString)
        XCTAssertFalse(link.matchesAuthorizationHeader(nil))
        XCTAssertFalse(link.matchesAuthorizationHeader("bearer " + link.token))
        XCTAssertFalse(link.matchesAuthorizationHeader("Bearer  " + link.token))
        XCTAssertFalse(link.matchesAuthorizationHeader(link.authorizationHeader + " "))
        XCTAssertFalse(link.matchesAuthorizationHeader("Bearer B" + link.token.dropFirst()))
        XCTAssertFalse(link.matchesAuthorizationHeader("Bearer " + link.token.dropLast() + "A"))

        let newToken = ShareLink.generateToken()
        XCTAssertEqual(newToken.utf8.count, 43)
        let fresh = try ShareLink(
            host: link.host, port: link.port, shareID: UUID(), token: newToken,
            expiresAtUnixSeconds: link.expiresAtUnixSeconds
        )
        XCTAssertTrue(fresh.matchesAuthorizationHeader("Bearer " + newToken))
        XCTAssertEqual(fresh, try ShareLink(scannedValue: fresh.qrString))
    }

    func testExpiryAndClockSkew() throws {
        let example = try wireExample()
        let link = try ShareLink(scannedValue: example.qrString)
        let deadline = Date(timeIntervalSince1970: TimeInterval(link.expiresAtUnixSeconds))
        XCTAssertEqual(ShareLink.lifetimeSeconds, 180)
        XCTAssertFalse(link.isExpired(at: deadline.addingTimeInterval(-0.25)))
        XCTAssertTrue(link.isExpired(at: deadline))
        XCTAssertFalse(link.isExpired(at: deadline.addingTimeInterval(30), allowingClockSkew: true))
        XCTAssertTrue(link.isExpired(at: deadline.addingTimeInterval(30.25), allowingClockSkew: true))
    }

    func testExactMetadataBounds() throws {
        let digest = ShareMetadata.digest(of: Data())
        XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ShareMetadata.maximumFileBytes, 5_242_880)
        let name = String(repeating: "é", count: 510) + ".mdx"
        let project = String(repeating: "📓", count: 64)
        XCTAssertEqual(name.utf8.count, 1024)
        XCTAssertEqual(project.utf8.count, 256)
        let metadata = try ShareMetadata(filename: name, project: project, sha256: digest)
        let lowercaseHeaders = Dictionary(uniqueKeysWithValues: metadata.headers.map { ($0.key.lowercased(), $0.value) })
        XCTAssertEqual(metadata, try ShareMetadata(headers: lowercaseHeaders))
        XCTAssertThrowsError(try ShareMetadata(filename: name + "a", project: project, sha256: digest))
        XCTAssertThrowsError(try ShareMetadata(filename: name, project: project + "a", sha256: digest))

        var headers = metadata.headers
        headers[ShareMetadata.filenameHeader] = Data((name + "a").utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try ShareMetadata(headers: headers))
        headers = metadata.headers
        headers[ShareMetadata.projectHeader] = Data((project + "a").utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try ShareMetadata(headers: headers))
    }

    func testMalformedMetadata() throws {
        let validMetadata = try ShareMetadata(filename: "a.md", sha256: ShareMetadata.digest(of: Data()))
        XCTAssertNil(try ShareMetadata(headers: validMetadata.headers).project)
        for filename in ["", ".", "..", "folder/a.md", "folder\\a.md", "a\u{0}.md"] {
            XCTAssertThrowsError(try ShareMetadata(filename: filename, sha256: validMetadata.sha256))
        }
        for header in [ShareMetadata.filenameHeader, ShareMetadata.digestHeader] {
            var missing = validMetadata.headers
            missing.removeValue(forKey: header)
            XCTAssertThrowsError(try ShareMetadata(headers: missing))
        }
        for header in [ShareMetadata.filenameHeader, ShareMetadata.projectHeader] {
            for invalid in ["_w", "_x", "YQ==", "Y Q", "a", "+w", "YQ,Yg"] {
                var malformed = validMetadata.headers
                malformed[header] = invalid
                XCTAssertThrowsError(try ShareMetadata(headers: malformed))
            }
        }
        for invalid in ["abcdef", validMetadata.sha256.uppercased(), String(repeating: "g", count: 64)] {
            var malformed = validMetadata.headers
            malformed[ShareMetadata.digestHeader] = invalid
            XCTAssertThrowsError(try ShareMetadata(headers: malformed))
        }
        var ambiguous = validMetadata.headers
        ambiguous[ShareMetadata.filenameHeader.lowercased()] = ambiguous[ShareMetadata.filenameHeader]
        XCTAssertThrowsError(try ShareMetadata(headers: ambiguous))
    }

    func testMetadataPreservesUTF8Bytes() throws {
        let filename = "\u{FEFF}e\u{0301}.md"
        let project = "\u{FEFF}e\u{0301}"
        let metadata = try ShareMetadata(filename: filename, project: project, sha256: ShareMetadata.digest(of: Data()))
        let decoded = try ShareMetadata(headers: metadata.headers)
        XCTAssertEqual(Array(decoded.filename.utf8), Array(filename.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(decoded.project).utf8), Array(project.utf8))
    }
}
