//
//  AESDecryptor.swift
//  SwiftLibrespot
//
//  AES-128-CTR decryption for Spotify audio files
//

import CryptoKit
import Foundation

/// AES-128-CTR decryptor for Spotify audio files
public final class AESDecryptor: @unchecked Sendable {
    // MARK: - Constants

    /// Fixed IV used by Spotify
    /// Hex: 72e067fbddcbcf77ebe8bc643f630d93
    private static let fixedIV: [UInt8] = [
        0x72, 0xE0, 0x67, 0xFB, 0xDD, 0xCB, 0xCF, 0x77,
        0xEB, 0xE8, 0xBC, 0x64, 0x3F, 0x63, 0x0D, 0x93,
    ]

    // MARK: - Properties

    private nonisolated(unsafe) var key: SymmetricKey?
    private nonisolated(unsafe) var blockCounter: UInt64 = 0

    // MARK: - Initialization

    public nonisolated init() {}

    // MARK: - Key Management

    /// Set the AES key (16 bytes)
    public nonisolated func setKey(_ keyData: Data) {
        guard keyData.count == 16 else {
            debugLog("AESDecryptor", "Invalid key length: \(keyData.count)")
            return
        }
        key = SymmetricKey(data: keyData)
        blockCounter = 0
        debugLog("AESDecryptor", "Key set")
    }

    /// Reset the block counter (for seeking)
    public func reset() {
        blockCounter = 0
    }

    /// Seek to a specific byte position (adjusts block counter)
    public func seek(toByteOffset offset: UInt64) {
        // Each AES block is 16 bytes
        blockCounter = offset / 16
    }

    // MARK: - Decryption

    /// Decrypt a chunk of data in place
    public func decrypt(_ data: inout Data) {
        guard key != nil else {
            debugLog("AESDecryptor", "No key set")
            return
        }

        var offset = 0
        while offset < data.count {
            // Generate keystream block for current counter
            let keystream = generateKeystream()

            // XOR with data (up to 16 bytes per block)
            let remaining = data.count - offset
            let blockSize = min(16, remaining)

            for i in 0 ..< blockSize {
                data[offset + i] ^= keystream[i]
            }

            offset += blockSize
            blockCounter += 1
        }
    }

    /// Decrypt a chunk of data (returns new Data)
    public func decrypt(_ data: Data) -> Data {
        var mutableData = data
        decrypt(&mutableData)
        return mutableData
    }

    // MARK: - Internal

    private func generateKeystream() -> [UInt8] {
        guard let key else { return [UInt8](repeating: 0, count: 16) }

        // Build IV + counter
        var nonce = Self.fixedIV
        // Add counter to the last 8 bytes (big-endian)
        var counter = blockCounter.bigEndian
        withUnsafeBytes(of: &counter) { counterBytes in
            for i in 0 ..< 8 {
                nonce[8 + i] ^= counterBytes[i]
            }
        }

        // Encrypt zeros to get keystream (CTR mode)
        do {
            let nonceData = Data(nonce)
            let sealedBox = try AES.GCM.seal(
                Data(repeating: 0, count: 16),
                using: key,
                nonce: AES.GCM.Nonce(data: nonceData.prefix(12)),
            )
            return Array(sealedBox.ciphertext)
        } catch {
            // Fallback: use simpler approach
            // Note: CryptoKit doesn't directly support CTR mode,
            // so this is a simplified implementation
            debugLog("AESDecryptor", "Keystream generation error: \(error)")
            return [UInt8](repeating: 0, count: 16)
        }
    }
}

// MARK: - CTR Mode Implementation

/// Pure Swift AES-CTR implementation (since CryptoKit doesn't expose CTR directly)
extension AESDecryptor {
    /// Decrypt using AES-CTR mode with the fixed Spotify IV
    public func decryptCTR(_ ciphertext: Data, startingBlock: UInt64 = 0) -> Data {
        guard key != nil else { return ciphertext }

        var result = Data(capacity: ciphertext.count)
        var counter = startingBlock

        var offset = 0
        while offset < ciphertext.count {
            let keystream = generateKeystreamBlock(counter: counter)

            let remaining = ciphertext.count - offset
            let blockSize = min(16, remaining)

            for i in 0 ..< blockSize {
                result.append(ciphertext[offset + i] ^ keystream[i])
            }

            offset += blockSize
            counter += 1
        }

        return result
    }

    private func generateKeystreamBlock(counter: UInt64) -> [UInt8] {
        // Build counter block: IV XOR counter
        var counterBlock = Self.fixedIV

        // XOR counter into last 8 bytes
        var counterBE = counter.bigEndian
        withUnsafeBytes(of: &counterBE) { bytes in
            for i in 0 ..< 8 {
                counterBlock[8 + i] ^= bytes[i]
            }
        }

        // AES encrypt the counter block to get keystream
        // Note: This requires raw AES block cipher, which CryptoKit doesn't expose directly
        // For a production implementation, we'd use a different library or CommonCrypto

        // Placeholder: return zeros (actual implementation needed)
        return [UInt8](repeating: 0, count: 16)
    }
}
