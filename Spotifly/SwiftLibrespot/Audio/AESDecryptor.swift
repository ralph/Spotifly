//
//  AESDecryptor.swift
//  SwiftLibrespot
//
//  AES-128-CTR decryption for Spotify audio files
//

import CommonCrypto
import Foundation

/// AES-128-CTR decryptor for Spotify audio files
public final class AESDecryptor: @unchecked Sendable {
    // MARK: - Constants

    /// Fixed IV used by Spotify
    /// Hex: 72e067fbddcbcf77ebe8bc643f630d93
    private nonisolated(unsafe) static var fixedIV: [UInt8] {
        [
            0x72, 0xE0, 0x67, 0xFB, 0xDD, 0xCB, 0xCF, 0x77,
            0xEB, 0xE8, 0xBC, 0x64, 0x3F, 0x63, 0x0D, 0x93,
        ]
    }

    // MARK: - Properties

    private nonisolated(unsafe) var keyBytes: [UInt8]?
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
        keyBytes = Array(keyData)
        blockCounter = 0
        debugLog("AESDecryptor", "Key set")
    }

    /// Reset the block counter (for seeking)
    public nonisolated func reset() {
        blockCounter = 0
    }

    /// Seek to a specific byte position (adjusts block counter)
    public nonisolated func seek(toByteOffset offset: UInt64) {
        // Each AES block is 16 bytes
        blockCounter = offset / 16
    }

    // MARK: - Decryption

    /// Decrypt a chunk of data in place
    public nonisolated func decrypt(_ data: inout Data) {
        guard keyBytes != nil else {
            debugLog("AESDecryptor", "No key set")
            return
        }

        var offset = 0
        while offset < data.count {
            // Generate keystream block for current counter
            let keystream = generateKeystreamBlock(counter: blockCounter)

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
    public nonisolated func decrypt(_ data: Data) -> Data {
        var mutableData = data
        decrypt(&mutableData)
        return mutableData
    }

    /// Decrypt using AES-CTR mode with the fixed Spotify IV
    public nonisolated func decryptCTR(_ ciphertext: Data, startingBlock: UInt64 = 0) -> Data {
        guard keyBytes != nil else { return ciphertext }

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

    // MARK: - Keystream Generation using CommonCrypto

    private nonisolated func generateKeystreamBlock(counter: UInt64) -> [UInt8] {
        guard let key = keyBytes else {
            return [UInt8](repeating: 0, count: 16)
        }

        // Build counter block: IV with counter XORed into last 8 bytes
        var counterBlock = Self.fixedIV

        // XOR counter (big-endian) into last 8 bytes of IV
        var counterBE = counter.bigEndian
        withUnsafeBytes(of: &counterBE) { bytes in
            for i in 0 ..< 8 {
                counterBlock[8 + i] ^= bytes[i]
            }
        }

        // AES-ECB encrypt the counter block to get keystream
        var keystream = [UInt8](repeating: 0, count: 16)
        var outputLength: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode), // ECB for single block
            key,
            key.count,
            nil, // No IV for ECB
            counterBlock,
            counterBlock.count,
            &keystream,
            keystream.count,
            &outputLength,
        )

        if status != kCCSuccess {
            debugLog("AESDecryptor", "CCCrypt failed with status: \(status)")
            return [UInt8](repeating: 0, count: 16)
        }

        return keystream
    }
}
