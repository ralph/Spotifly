//
//  ShannonCipherTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// Known-answer vectors for the hand-written Shannon cipher, from the
/// reference implementation at https://github.com/twonky4/shannon.
///
/// These lived in an `Accesspoint.testShannonCipher()` that nothing called,
/// and were deleted with it during a dead-code pass. They are worth more than
/// that: Shannon carries every byte of the accesspoint session, so an error
/// here does not corrupt one field, it makes the connection unintelligible —
/// and the only thing exercising it otherwise is a live login.
struct ShannonCipherTests {
    private let key = Data([0x65, 0x87, 0xD8, 0x8F, 0x6C, 0x32, 0x9D, 0x8A, 0xE4, 0x6B])
    private let plaintext = Data("My secret message".utf8)

    @Test func `encryption matches the reference implementation`() {
        let expected = Data([
            0x91, 0x9D, 0xA9, 0xB6, 0x29, 0xFC, 0x9C, 0xDD, 0x17,
            0x8C, 0x15, 0x31, 0x9A, 0xAE, 0xCC, 0x6E, 0xD4,
        ])

        let cipher = ShannonCipher(key: key)
        var data = plaintext
        cipher.encrypt(&data)

        #expect(data == expected)
    }

    @Test func `the mac matches the reference implementation`() {
        let expected = Data([
            0xBE, 0x7B, 0xEF, 0x39, 0xEE, 0xFE, 0x54, 0xFD,
            0x8D, 0xB0, 0xBC, 0x6F, 0xD5, 0x30, 0x35, 0x19,
        ])

        let cipher = ShannonCipher(key: key)
        var data = plaintext
        cipher.encrypt(&data)

        #expect(cipher.finish(16) == expected)
    }

    /// The property the transport actually depends on, which the vectors above
    /// do not cover on their own: what one nonce encrypts, the same nonce
    /// decrypts. Every packet on the accesspoint socket rides its own nonce.
    @Test func `a nonced round trip returns the plaintext`() {
        let sender = ShannonCipher(key: key)
        sender.nonceU32(42)
        var data = plaintext
        sender.encrypt(&data)
        #expect(data != plaintext)

        let receiver = ShannonCipher(key: key)
        receiver.nonceU32(42)
        receiver.decrypt(&data)

        #expect(data == plaintext)
    }
}
