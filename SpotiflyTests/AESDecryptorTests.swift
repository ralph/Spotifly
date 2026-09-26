//
//  AESDecryptorTests.swift
//  SpotiflyTests
//

import CryptoKit
import Foundation
@testable import Spotifly
import Testing

/// Known answers for the audio cipher, produced independently by OpenSSL:
///
///     openssl enc -aes-128-ctr -K 000102030405060708090a0b0c0d0e0f \
///         -iv 72e067fbddcbcf77ebe8bc643f630d93 -in pt.bin -out ct.bin
///
/// where `pt.bin` is the 5000 bytes `(i * 7 + 3) & 0xff`. 5000 bytes is 313 blocks, so
/// the counter's low byte (0x93) wraps and carries into the next one — the case a
/// hand-rolled counter gets wrong first.
struct AESDecryptorTests {
    private let key = Data((0 ..< 16).map { UInt8($0) })
    private let plaintext = Data((0 ..< 5000).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })

    @Test func `decryption matches OpenSSL across a counter carry`() throws {
        let output = try AESDecryptor(key: key).decrypt(plaintext)

        #expect(output.count == 5000)
        #expect(output.prefix(32).hexString == "bdb84df61af13a9c0aa724352e15cec1bb1ed25af0ad7446954bdca533299719")
        #expect(output.suffix(16).hexString == "5fac88617eb6f976564a963e44491b96")
        #expect(
            SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
                == "def5f359213ea805118cf27577669f6ad3b7f7b89a65f187c7bb516051608285",
        )
    }

    /// The keystream continues across calls, so a file can be decrypted as it arrives.
    @Test func `chunked decryption equals decrypting at once`() throws {
        let whole = try AESDecryptor(key: key).decrypt(plaintext)

        let chunked = try AESDecryptor(key: key)
        var pieces = Data()
        var offset = 0
        for size in [1, 15, 16, 17, 1000, 3951] {
            pieces.append(chunked.decrypt(plaintext.subdata(in: offset ..< offset + size)))
            offset += size
        }

        #expect(offset == plaintext.count)
        #expect(pieces == whole)
    }
}
