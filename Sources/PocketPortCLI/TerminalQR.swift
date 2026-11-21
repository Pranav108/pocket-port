import CoreImage
import Darwin
import Foundation

enum TerminalQR {
    static func render(_ value: String, columns: Int) throws -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw CLIError("QR generator unavailable.") }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw CLIError("Cannot generate the QR code.") }
        let side = Int(output.extent.width)
        guard side > 0 && side <= 200 else { throw CLIError("Unexpected QR dimensions.") }
        guard let image = output.cgImage ?? CIContext().createCGImage(output, from: output.extent),
              let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                  bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let buffer = bitmap.data else { throw CLIError("Cannot render QR modules.") }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(output.extent)
        bitmap.interpolationQuality = .none
        bitmap.draw(image, in: output.extent)
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)
        func dark(_ x: Int, _ y: Int) -> Bool {
            (0..<side).contains(x) && (0..<side).contains(y) && pixels[y * side + x] < 128
        }
        defer { withExtendedLifetime(bitmap) {} }
        guard let inset = (0..<side).first(where: { dark($0, $0) }) else { throw CLIError("Empty QR code.") }
        let width = side - 2 * inset + 8
        guard columns > width else { throw CLIError("Widen the terminal to at least \(width + 1) columns.") }
        var lines = [String]()
        for row in stride(from: 0, to: width, by: 2) {
            var line = "\u{1B}[0;30;47m"
            for column in 0..<width {
                let x = column + inset - 4, y = row + inset - 4
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                default: line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }

    static func columns() throws -> Int {
        var size = winsize()
        guard isatty(STDOUT_FILENO) != 0, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            throw CLIError("Run pocket-port in an interactive terminal to display the QR code.")
        }
        return Int(size.ws_col)
    }
}
