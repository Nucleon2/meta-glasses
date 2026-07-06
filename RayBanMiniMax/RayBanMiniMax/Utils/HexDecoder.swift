//
//  HexDecoder.swift
//  RayBanMiniMax
//
//  MiniMax TTS responses ship audio as a lowercase hex string. This file
//  provides a fast, allocation-light Data initializer for hex strings.
//

import Foundation

extension Data {
    /// Initialize a `Data` blob from a hex-encoded string. Accepts any case
    /// and ignores common whitespace separators (spaces, newlines, `\r`, `\n`).
    /// Returns `nil` for invalid input.
    ///
    /// Example:
    ///   `Data(hexString: "48656c6c6f")` → `Data("Hello".utf8)`
    init?(hexString raw: String) {
        // Strip whitespace and a leading 0x/0X, if present.
        var hex = raw.filter { !$0.isWhitespace }
        if hex.lowercased().hasPrefix("0x") {
            hex.removeFirst(2)
        }

        // Odd length is invalid.
        guard hex.count % 2 == 0 else { return nil }

        // Pre-validate characters for fast failure.
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }

        self.init(bytes)
    }
}

extension String {
    /// True if every character is a hex digit (0-9, a-f, A-F).
    var isHexDigit: Bool {
        return self.allSatisfy { c in
            (c >= "0" && c <= "9") ||
            (c >= "a" && c <= "f") ||
            (c >= "A" && c <= "F")
        }
    }
}
