import Foundation

public struct ShareLink: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum ValidationError: Error, Equatable {
        case invalidLink
    }

    public static let lifetimeSeconds: Int64 = 180
    public static let clockSkewSeconds: Int64 = 30
    private static let maximumLinkBytes = 512
    private static let tokenByteCount = 32
    private static let tokenEncodedLength = 43
    private static let authorizationPrefix = "Bearer "

    public let host: String
    public let port: Int
    public let shareID: UUID
    public let token: String
    public let expiresAtUnixSeconds: Int64

    public init(host: String, port: Int, shareID: UUID, token: String, expiresAtUnixSeconds: Int64) throws {
        guard Self.isValidHost(host),
              (1...65535).contains(port),
              token.utf8.prefix(Self.tokenEncodedLength + 1).count == Self.tokenEncodedLength,
              Base64URL.decode(token, maximumByteCount: Self.tokenByteCount)?.count == Self.tokenByteCount,
              expiresAtUnixSeconds > 0 else {
            throw ValidationError.invalidLink
        }
        self.host = host.lowercased()
        self.port = port
        self.shareID = shareID
        self.token = token
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }

    public init(scannedValue: String) throws {
        // Parse the wire spelling before URLComponents can normalize it.
        guard scannedValue.utf8.prefix(Self.maximumLinkBytes + 1).count <= Self.maximumLinkBytes,
              scannedValue.hasPrefix("http://") else {
            throw ValidationError.invalidLink
        }

        let parts = scannedValue.dropFirst("http://".count).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ValidationError.invalidLink
        }

        let path = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5,
              path[1] == "share-md",
              path[2] == "v1",
              let shareID = UUID(uuidString: String(path[3])),
              path[3] == shareID.uuidString.lowercased(),
              path[4] == "file" else {
            throw ValidationError.invalidLink
        }

        let authority = path[0].split(separator: ":", omittingEmptySubsequences: false)
        let fragment = parts[1].split(separator: "&", omittingEmptySubsequences: false)
        guard authority.count == 2,
              let port = Int(authority[1]),
              authority[1] == String(port),
              fragment.count == 2,
              fragment[0].hasPrefix("token="),
              fragment[1].hasPrefix("expires=") else {
            throw ValidationError.invalidLink
        }

        let expiration = fragment[1].dropFirst("expires=".count)
        guard let expiresAtUnixSeconds = Int64(expiration),
              expiration == String(expiresAtUnixSeconds) else {
            throw ValidationError.invalidLink
        }

        try self.init(
            host: String(authority[0]),
            port: port,
            shareID: shareID,
            token: String(fragment[0].dropFirst("token=".count)),
            expiresAtUnixSeconds: expiresAtUnixSeconds
        )
    }

    public var qrString: String {
        var qr = components(route: "file")
        qr.fragment = "token=\(token)&expires=\(expiresAtUnixSeconds)"
        // All URL components have already been validated.
        return qr.url!.absoluteString
    }

    public var downloadURL: URL {
        components(route: "file").url!
    }

    public var acknowledgmentURL: URL {
        components(route: "ack").url!
    }

    public var authorizationHeader: String {
        Self.authorizationPrefix + token
    }

    public var description: String {
        "ShareLink"
    }

    public var debugDescription: String {
        description
    }

    public static func generateToken() -> String {
        var random = SystemRandomNumberGenerator()
        let bytes = Data((0..<tokenByteCount).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        return Base64URL.encode(bytes)
    }

    public func matchesAuthorizationHeader(_ header: String?) -> Bool {
        guard let header,
              header.hasPrefix(Self.authorizationPrefix) else {
            return false
        }
        let candidate = header.utf8.dropFirst(Self.authorizationPrefix.utf8.count)
        guard candidate.prefix(Self.tokenEncodedLength + 1).count == Self.tokenEncodedLength else {
            return false
        }

        // Compare every byte of the fixed-length credential before checking the result.
        var difference: UInt8 = 0
        for (expected, supplied) in zip(token.utf8, candidate) {
            difference |= expected ^ supplied
        }
        return difference == 0
    }

    public func isExpired(at date: Date, allowingClockSkew: Bool = false) -> Bool {
        let deadline = TimeInterval(expiresAtUnixSeconds)
        if allowingClockSkew {
            return date.timeIntervalSince1970 > deadline + TimeInterval(Self.clockSkewSeconds)
        }
        return date.timeIntervalSince1970 >= deadline
    }

    private func components(route: String) -> URLComponents {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/share-md/v1/\(shareID.uuidString.lowercased())/\(route)"
        return components
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard host.utf8.prefix(70).count <= 69 else {
            return false
        }
        let labels = host.utf8.split(separator: 46, omittingEmptySubsequences: false)
        guard labels.count == 2, (1...63).contains(labels[0].count),
              String(decoding: labels[1], as: UTF8.self).lowercased() == "local",
              let first = labels[0].first, let last = labels[0].last,
              isDNSLetterOrDigit(first), isDNSLetterOrDigit(last) else {
            return false
        }
        return labels[0].allSatisfy { isDNSLetterOrDigit($0) || $0 == 45 }
    }

    private static func isDNSLetterOrDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57: true
        default: false
        }
    }
}
