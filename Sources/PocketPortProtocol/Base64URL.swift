import Foundation

enum Base64URL {
    static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String, maximumByteCount: Int) -> Data? {
        let maximumEncodedLength = (4 * maximumByteCount + 2) / 3
        guard value.utf8.prefix(maximumEncodedLength + 1).count <= maximumEncodedLength,
              value.utf8.allSatisfy(isAlphabetByte) else {
            return nil
        }

        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - standard.utf8.count % 4) % 4
        guard let bytes = Data(base64Encoded: standard + String(repeating: "=", count: padding)),
              bytes.count <= maximumByteCount,
              encode(bytes) == value else {
            return nil
        }
        return bytes
    }

    private static func isAlphabetByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57, 45, 95: true
        default: false
        }
    }
}
