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
    private nonisolated static let fixedIV: [UInt8] = [
        0x72, 0xE0, 0x67, 0xFB, 0xDD, 0xCB, 0xCF, 0x77,
        0xEB, 0xE8, 0xBC, 0x64, 0x3F, 0x63, 0x0D, 0x93,
    ]

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

    // MARK: - Keystream Generation using CommonCrypto

    /// Builds the counter block for `counter`: the fixed IV interpreted as a
    /// 128-bit big-endian integer, plus the block index — standard CTR
    /// semantics (`Ctr128BE` in librespot), where carries ripple upward across
    /// the whole block. XORing instead would corrupt everything past the first
    /// 16 bytes.
    private nonisolated func generateKeystreamBlock(counter: UInt64) -> [UInt8] {
        guard let key = keyBytes else {
            return [UInt8](repeating: 0, count: 16)
        }

        var counterBlock = Self.fixedIV

        // Add `counter` into the big-endian 128-bit value, from the least
        // significant byte (index 15) upward, propagating the carry.
        var carry = counter
        var index = 15
        while carry > 0 {
            let total = UInt64(counterBlock[index]) + (carry & 0xFF)
            counterBlock[index] = UInt8(truncatingIfNeeded: total)
            carry = (carry >> 8) + (total >> 8)
            if index == 0 {
                break // wraps modulo 2^128, as CTR requires
            }
            index -= 1
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
