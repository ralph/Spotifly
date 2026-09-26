//
//  AESDecryptor.swift
//  SwiftLibrespot
//
//  AES-128-CTR decryption for Spotify audio files
//

import CommonCrypto
import Foundation

/// AES-128-CTR with Spotify's fixed IV, keystream from block 0 — librespot's
/// `Ctr128BE`, where the counter is the whole 128-bit block, big-endian.
///
/// One CommonCrypto CTR cryptor rather than an ECB call per 16-byte block: the
/// per-block version allocated three arrays and crossed into CommonCrypto a
/// quarter of a million times for an ordinary track. The keystream carries on
/// across calls, so a file can be decrypted in the pieces it arrives in.
final nonisolated class AESDecryptor: @unchecked Sendable {
    private static let iv: [UInt8] = [
        0x72, 0xE0, 0x67, 0xFB, 0xDD, 0xCB, 0xCF, 0x77,
        0xEB, 0xE8, 0xBC, 0x64, 0x3F, 0x63, 0x0D, 0x93,
    ]

    private let cryptor: CCCryptorRef

    /// - Parameter key: the 16-byte audio key from the accesspoint.
    init(key: Data) throws {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), // CTR decrypts by encrypting the counter
                CCMode(kCCModeCTR),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                Self.iv,
                keyBytes.baseAddress,
                key.count,
                nil,
                0,
                0,
                0,
                &cryptor,
            )
        }
        guard status == kCCSuccess, let cryptor else {
            throw LibrespotError.decryptionFailed("AES-CTR setup failed (\(status), \(key.count)-byte key)")
        }
        self.cryptor = cryptor
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    /// Decrypts the next `data.count` bytes of the file.
    func decrypt(_ data: Data) -> Data {
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, data.count, &moved)
            }
        }
        precondition(status == kCCSuccess && moved == data.count, "AES-CTR update failed: \(status)")
        return output
    }
}
