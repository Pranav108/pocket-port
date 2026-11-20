import Foundation
import ShareProtocol

struct Request {
    let method: String
    let path: String
    let authorization: String?
    static let maximumBytes = 8192

    static func parse(_ bytes: Data) throws -> Self? {
        let invalid = CLIError("Invalid request.")
        guard bytes.count <= maximumBytes else { throw invalid }
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard end.upperBound == bytes.endIndex,
              let text = String(data: bytes[..<end.lowerBound], encoding: .ascii) else { throw invalid }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1",
              parts[0].utf8.allSatisfy({ (65...90).contains($0) }), !parts[0].isEmpty,
              parts[1].hasPrefix("/"), parts[1].utf8.allSatisfy({ (33...126).contains($0) }) else { throw invalid }
        var fields = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw invalid }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || "!#$%&'*+-.^`_|~".utf8.contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  fields.updateValue(value.trimmingCharacters(in: .whitespaces), forKey: name) == nil else { throw invalid }
        }
        guard let host = fields["host"], !host.isEmpty, fields["transfer-encoding"] == nil,
              fields["expect"] == nil, fields["content-length", default: "0"] == "0" else { throw invalid }
        return Self(method: String(parts[0]), path: String(parts[1]), authorization: fields["authorization"])
    }
}

struct Reply {
    let status: Int
    var headers = [String: String]()
    var bytes = Data()

    var head: Data {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 410: "Gone"]
        var text = "HTTP/1.1 \(status) \(reasons[status]!)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if status != 204 { text += "Content-Length: \(bytes.count)\r\n" }
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }
}

struct Session {
    let link: ShareLink
    private(set) var snapshot: FileSnapshot?
    let deadline: DispatchTime
    private(set) var acknowledged = false
    init(link: ShareLink, snapshot: FileSnapshot, deadline: DispatchTime) {
        self.link = link
        self.snapshot = snapshot
        self.deadline = deadline
    }
    mutating func respond(_ request: Request, now: DispatchTime) -> Reply {
        let get = request.method == "GET" && request.path == link.downloadURL.path
        let ack = request.method == "POST" && request.path == link.acknowledgmentURL.path
        guard (get || ack) && link.matchesAuthorizationHeader(request.authorization) else { return Reply(status: 404) }
        if acknowledged && ack { return Reply(status: 204) }
        guard now < deadline, let snapshot else { return Reply(status: 410) }
        if ack {
            acknowledged = true
            self.snapshot = nil
            return Reply(status: 204)
        }
        var headers = snapshot.metadata.headers
        headers["Content-Type"] = ShareMetadata.contentType
        return Reply(status: 200, headers: headers, bytes: snapshot.bytes)
    }
}
