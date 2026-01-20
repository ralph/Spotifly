//
//  DiffieHellman.swift
//  SwiftLibrespot
//
//  Diffie-Hellman key exchange for Spotify accesspoint handshake
//  Uses the 1536-bit MODP group specified by Spotify's protocol
//

import Foundation

/// Diffie-Hellman key exchange implementation
/// Uses a custom 1536-bit MODP group (generator=2, specific prime)
public final class DiffieHellman: @unchecked Sendable {
    // MARK: - Constants

    /// Generator (g = 2)
    private nonisolated static let generator = BigUInt(2)

    /// 768-bit MODP prime (Spotify's custom prime, same as librespot)
    private nonisolated static let prime: BigUInt = {
        let primeBytes: [UInt8] = [
            // Spotify's 768-bit prime (96 bytes) - from librespot source
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2, 0x21, 0x68, 0xC2, 0x34,
            0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1, 0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74,
            0x02, 0x0B, 0xBE, 0xA6, 0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
            0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D, 0xF2, 0x5F, 0x14, 0x37,
            0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45, 0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6,
            0xF4, 0x4C, 0x42, 0xE9, 0xA6, 0x3A, 0x36, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ]
        return BigUInt(Data(primeBytes))
    }()

    // MARK: - Properties

    private nonisolated(unsafe) var privateKey: BigUInt
    private nonisolated(unsafe) var publicKey: BigUInt
    private nonisolated(unsafe) var _sharedSecret: Data?

    /// Our public key bytes
    public nonisolated var publicKeyBytes: Data {
        publicKey.toData()
    }

    /// Computed shared secret (available after exchange)
    public nonisolated var sharedSecret: Data? {
        _sharedSecret
    }

    // MARK: - Initialization

    /// Create a new DH key pair
    public nonisolated init() throws {
        // Generate 95 random bytes for private key (760 bits, matching go-librespot)
        var privateKeyData = Data(count: 95)
        let result = privateKeyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 95, bytes.baseAddress!)
        }

        guard result == errSecSuccess else {
            throw LibrespotError.encryptionError("Failed to generate random private key")
        }

        privateKey = BigUInt(privateKeyData)

        // publicKey = generator^privateKey mod prime
        publicKey = Self.modPow(base: Self.generator, exponent: privateKey, modulus: Self.prime)

        debugLog("DiffieHellman", "Generated key pair, public key: \(publicKey.toData().count) bytes")
    }

    // MARK: - Key Exchange

    /// Exchange keys with the server and compute shared secret
    /// - Parameter remotePublicKeyBytes: Server's public key
    /// - Returns: Shared secret bytes (minimal representation, like librespot)
    public nonisolated func exchange(remotePublicKeyBytes: Data) -> Data {
        let remotePublicKey = BigUInt(remotePublicKeyBytes)

        // sharedSecret = remotePublicKey^privateKey mod prime
        let secret = Self.modPow(base: remotePublicKey, exponent: privateKey, modulus: Self.prime)
        let secretData = secret.toData()

        // Use minimal representation (like librespot's to_bytes_be)
        _sharedSecret = secretData

        debugLog("DiffieHellman", "Key exchange complete, shared secret: \(_sharedSecret!.count) bytes")

        return _sharedSecret!
    }

    // MARK: - Modular Exponentiation

    /// Compute (base^exponent) mod modulus using square-and-multiply
    private nonisolated static func modPow(base: BigUInt, exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        if modulus == BigUInt(1) {
            return BigUInt(0)
        }

        var result = BigUInt(1)
        var b = base % modulus
        var e = exponent

        while e > BigUInt(0) {
            if e.isOdd {
                result = (result * b) % modulus
            }
            e = e >> 1
            b = (b * b) % modulus
        }

        return result
    }
}

// MARK: - Simple BigUInt Implementation

/// Minimal big integer implementation for DH calculations
/// Only supports operations needed for DH key exchange
public struct BigUInt: Sendable, Comparable, Equatable {
    // Store as array of UInt64 words, little-endian order
    private var words: [UInt64]

    /// Initialize from integer
    public nonisolated init(_ value: UInt64 = 0) {
        if value == 0 {
            words = []
        } else {
            words = [value]
        }
    }

    /// Initialize from Data (big-endian)
    public nonisolated init(_ data: Data) {
        // Convert big-endian data to little-endian words
        var tempWords: [UInt64] = []
        let count = data.count

        // Process 8 bytes at a time, from the end
        var i = count
        while i > 0 {
            let start = max(i - 8, 0)
            let chunk = data[start ..< i]

            var word: UInt64 = 0
            for (idx, byte) in chunk.enumerated() {
                word |= UInt64(byte) << (8 * (chunk.count - 1 - idx))
            }
            tempWords.append(word)

            i = start
        }

        // Remove leading zeros
        while tempWords.last == 0 {
            tempWords.removeLast()
        }

        words = tempWords
    }

    /// Convert to Data (big-endian)
    public nonisolated func toData() -> Data {
        if words.isEmpty {
            return Data([0])
        }

        var result = Data()

        // Process words from most significant to least
        for i in (0 ..< words.count).reversed() {
            let word = words[i]
            if i == words.count - 1 {
                // For the most significant word, skip leading zeros
                var started = false
                for shift in stride(from: 56, through: 0, by: -8) {
                    let byte = UInt8((word >> shift) & 0xFF)
                    if byte != 0 || started {
                        result.append(byte)
                        started = true
                    }
                }
                if !started {
                    result.append(0)
                }
            } else {
                // For other words, include all 8 bytes
                for shift in stride(from: 56, through: 0, by: -8) {
                    result.append(UInt8((word >> shift) & 0xFF))
                }
            }
        }

        return result
    }

    /// Check if odd
    public nonisolated var isOdd: Bool {
        !words.isEmpty && (words[0] & 1) == 1
    }

    /// Right shift by n bits
    public nonisolated static func >> (lhs: BigUInt, rhs: Int) -> BigUInt {
        if lhs.words.isEmpty || rhs == 0 {
            return lhs
        }

        let wordShift = rhs / 64
        let bitShift = rhs % 64

        if wordShift >= lhs.words.count {
            return BigUInt(0)
        }

        var result: [UInt64] = []

        for i in wordShift ..< lhs.words.count {
            var word = lhs.words[i] >> bitShift
            if bitShift > 0, i + 1 < lhs.words.count {
                word |= lhs.words[i + 1] << (64 - bitShift)
            }
            result.append(word)
        }

        // Remove leading zeros
        while result.last == 0 {
            result.removeLast()
        }

        var ret = BigUInt()
        ret.words = result
        return ret
    }

    /// Comparison
    public nonisolated static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count < rhs.words.count
        }
        for i in (0 ..< lhs.words.count).reversed() {
            if lhs.words[i] != rhs.words[i] {
                return lhs.words[i] < rhs.words[i]
            }
        }
        return false
    }

    public nonisolated static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        lhs.words == rhs.words
    }

    public nonisolated static func > (lhs: BigUInt, rhs: BigUInt) -> Bool {
        rhs < lhs
    }

    /// Addition
    public nonisolated static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let maxLen = max(lhs.words.count, rhs.words.count)
        var result: [UInt64] = []
        var carry: UInt64 = 0

        for i in 0 ..< maxLen {
            let a = i < lhs.words.count ? lhs.words[i] : 0
            let b = i < rhs.words.count ? rhs.words[i] : 0

            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)

            result.append(sum2)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }

        if carry > 0 {
            result.append(carry)
        }

        var ret = BigUInt()
        ret.words = result
        return ret
    }

    /// Subtraction (assumes lhs >= rhs)
    public nonisolated static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        var borrow: UInt64 = 0

        for i in 0 ..< lhs.words.count {
            let a = lhs.words[i]
            let b = i < rhs.words.count ? rhs.words[i] : 0

            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)

            result.append(diff2)
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }

        // Remove leading zeros
        while result.last == 0 {
            result.removeLast()
        }

        var ret = BigUInt()
        ret.words = result
        return ret
    }

    /// Multiplication
    public nonisolated static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.words.isEmpty || rhs.words.isEmpty {
            return BigUInt(0)
        }

        var result = [UInt64](repeating: 0, count: lhs.words.count + rhs.words.count)

        for i in 0 ..< lhs.words.count {
            var carry: UInt64 = 0
            for j in 0 ..< rhs.words.count {
                let pos = i + j
                let (high, low) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])

                // Add low part + previous carry
                let (sum1, o1) = result[pos].addingReportingOverflow(low)
                let (sum2, o2) = sum1.addingReportingOverflow(carry)
                result[pos] = sum2

                // Compute new carry (includes high bits and any overflow)
                carry = high + (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }

            // Propagate remaining carry AFTER inner loop completes
            var carryPos = i + rhs.words.count
            while carry > 0, carryPos < result.count {
                let (sum, overflow) = result[carryPos].addingReportingOverflow(carry)
                result[carryPos] = sum
                carry = overflow ? 1 : 0
                carryPos += 1
            }
        }

        // Remove leading zeros
        while result.last == 0, !result.isEmpty {
            result.removeLast()
        }

        var ret = BigUInt()
        ret.words = result
        return ret
    }

    /// Modulo
    public nonisolated static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if rhs.words.isEmpty {
            fatalError("Division by zero")
        }

        if lhs < rhs {
            return lhs
        }

        // Simple repeated subtraction for small cases
        // For large numbers, use long division
        return longDivisionRemainder(lhs, rhs)
    }

    /// Long division to get remainder
    private nonisolated static func longDivisionRemainder(_ dividend: BigUInt, _ divisor: BigUInt) -> BigUInt {
        if dividend < divisor {
            return dividend
        }

        // Estimate bit positions
        let dividendBits = dividend.bitLength
        let divisorBits = divisor.bitLength

        var remainder = dividend
        var shift = dividendBits - divisorBits

        while shift >= 0 {
            let shifted = divisor << shift
            if remainder >= shifted {
                remainder = remainder - shifted
            }
            shift -= 1
        }

        return remainder
    }

    /// Left shift by n bits
    public nonisolated static func << (lhs: BigUInt, rhs: Int) -> BigUInt {
        if lhs.words.isEmpty || rhs == 0 {
            return lhs
        }

        let wordShift = rhs / 64
        let bitShift = rhs % 64

        var result = [UInt64](repeating: 0, count: lhs.words.count + wordShift + 1)

        for i in 0 ..< lhs.words.count {
            result[i + wordShift] |= lhs.words[i] << bitShift
            if bitShift > 0, i + wordShift + 1 < result.count {
                result[i + wordShift + 1] |= lhs.words[i] >> (64 - bitShift)
            }
        }

        // Remove leading zeros
        while result.last == 0 {
            result.removeLast()
        }

        var ret = BigUInt()
        ret.words = result
        return ret
    }

    /// Number of bits
    private nonisolated var bitLength: Int {
        if words.isEmpty {
            return 0
        }
        let lastWord = words.last!
        return (words.count - 1) * 64 + (64 - lastWord.leadingZeroBitCount)
    }

    /// Greater than or equal
    public nonisolated static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        !(lhs < rhs)
    }
}
