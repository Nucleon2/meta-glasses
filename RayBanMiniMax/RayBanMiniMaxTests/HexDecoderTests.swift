//
//  HexDecoderTests.swift
//

import Testing
@testable import RayBanMiniMaxCore

@Suite("HexDecoder")
struct HexDecoderTests {

    @Test("Basic ASCII")
    func basicAscii() {
        let data = Data(hexString: "48656c6c6f")
        #expect(data == Data("Hello".utf8))
    }

    @Test("Uppercase hex")
    func uppercase() {
        let data = Data(hexString: "DEADBEEF")
        #expect(data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Whitespace tolerated")
    func whitespace() {
        let data = Data(hexString: "  De Ad Be Ef\n")
        #expect(data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Empty string")
    func empty() {
        #expect(Data(hexString: "") == Data())
    }

    @Test("Invalid characters rejected")
    func invalid() {
        #expect(Data(hexString: "ZZ") == nil)
        #expect(Data(hexString: "1") == nil) // odd length
    }
}
