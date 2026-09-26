//
//  DiffieHellman.swift
//  SwiftLibrespot
//
//  Diffie-Hellman key exchange for the accesspoint handshake: generator 2 over
//  Spotify's 768-bit prime (RFC 2409's first Oakley group), as librespot has it.
//

import Foundation

/// One side of the accesspoint key exchange.
///
/// Both halves are a single modular exponentiation, done in Montgomery form over
/// twelve 64-bit limbs. The general-purpose big integer this replaced reduced
/// after every multiply by shifting and subtracting one *bit* at a time, which
/// made the two exponentiations cost about five seconds of every connect.
public final nonisolated class DiffieHellman: Sendable {
    private let privateKey: Data

    /// Our public key, `g^x mod p`, big-endian with no leading zero bytes —
    /// librespot's `to_bytes_be()`, which is what the handshake HMAC covers.
    public let publicKeyBytes: Data

    /// A fresh key pair: 95 random bytes of exponent, as librespot and
    /// go-librespot use.
    public convenience init() throws {
        var bytes = [UInt8](repeating: 0, count: 95)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LibrespotError.encryptionError("Failed to generate random private key")
        }
        self.init(privateKey: Data(bytes))
    }

    /// A key pair from a known exponent. Deterministic, which is what tests need.
    init(privateKey: Data) {
        self.privateKey = privateKey
        publicKeyBytes = Montgomery768.power(Montgomery768.generator, privateKey).bigEndianMinimal
        debugLog("DiffieHellman", "Generated key pair, public key: \(publicKeyBytes.count) bytes")
    }

    /// The shared secret for the server's public key, minimal big-endian like
    /// the public key.
    public func exchange(remotePublicKeyBytes: Data) -> Data {
        let remote = Montgomery768.Number(bigEndian: remotePublicKeyBytes)
        return Montgomery768.power(remote, privateKey).bigEndianMinimal
    }
}

/// Modular exponentiation for the one prime the handshake uses.
private nonisolated enum Montgomery768 {
    static let limbs = 12

    /// Little-endian 64-bit limbs of a number below the prime.
    struct Number {
        var words: [UInt64]

        init(words: [UInt64]) {
            self.words = words
        }

        /// Reads big-endian bytes. Anything wider than 768 bits keeps its low bits,
        /// which cannot happen for a key the peer computed mod p.
        init(bigEndian bytes: Data) {
            var words = [UInt64](repeating: 0, count: limbs)
            for (index, byte) in bytes.reversed().enumerated() where index < limbs * 8 {
                words[index / 8] |= UInt64(byte) << (8 * UInt64(index % 8))
            }
            self.words = words
        }

        var bigEndianMinimal: Data {
            var bytes = [UInt8]()
            bytes.reserveCapacity(limbs * 8)
            for word in words.reversed() {
                for shift in stride(from: 56, through: 0, by: -8) {
                    bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
                }
            }
            let first = bytes.firstIndex { $0 != 0 } ?? bytes.count - 1
            return Data(bytes[first...])
        }
    }

    static let prime = Number(bigEndian: Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2, 0x21, 0x68, 0xC2, 0x34,
        0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1, 0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74,
        0x02, 0x0B, 0xBE, 0xA6, 0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
        0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D, 0xF2, 0x5F, 0x14, 0x37,
        0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45, 0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6,
        0xF4, 0x4C, 0x42, 0xE9, 0xA6, 0x3A, 0x36, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    ]))

    static let generator = Number(bigEndian: Data([2]))

    /// `-p⁻¹ mod 2⁶⁴`, by Newton iteration on the low limb.
    private static let inverse: UInt64 = {
        var inverse: UInt64 = 1
        for _ in 0 ..< 6 {
            inverse = inverse &* (2 &- prime.words[0] &* inverse)
        }
        return 0 &- inverse
    }()

    /// `R² mod p` for `R = 2⁷⁶⁸`: one, doubled 1536 times. Converts into Montgomery form.
    private static let rSquared: Number = {
        var value = Number(bigEndian: Data([1]))
        for _ in 0 ..< 2 * limbs * 64 {
            value = addModulo(value, value)
        }
        return value
    }()

    /// `base^exponent mod p`, exponent in big-endian bytes.
    static func power(_ base: Number, _ exponent: Data) -> Number {
        let one = Number(bigEndian: Data([1]))
        let montgomeryBase = multiply(base, rSquared)
        var result = multiply(one, rSquared)

        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = multiply(result, result)
                if (byte >> UInt8(bit)) & 1 == 1 {
                    result = multiply(result, montgomeryBase)
                }
            }
        }
        return multiply(result, one)
    }

    /// Montgomery product `a·b·R⁻¹ mod p` (CIOS).
    private static func multiply(_ a: Number, _ b: Number) -> Number {
        let p = prime.words
        var t = [UInt64](repeating: 0, count: limbs + 2)

        for i in 0 ..< limbs {
            var carry: UInt64 = 0
            for j in 0 ..< limbs {
                (carry, t[j]) = multiplyAdd(a.words[j], b.words[i], t[j], carry)
            }
            let (sum, overflow) = t[limbs].addingReportingOverflow(carry)
            t[limbs] = sum
            t[limbs + 1] = overflow ? 1 : 0

            let m = t[0] &* inverse
            (carry, _) = multiplyAdd(m, p[0], t[0], 0)
            for j in 1 ..< limbs {
                (carry, t[j - 1]) = multiplyAdd(m, p[j], t[j], carry)
            }
            let (top, topOverflow) = t[limbs].addingReportingOverflow(carry)
            t[limbs - 1] = top
            t[limbs] = t[limbs + 1] &+ (topOverflow ? 1 : 0)
        }

        let result = Number(words: Array(t[0 ..< limbs]))
        return t[limbs] != 0 || !isBelowPrime(result) ? subtractPrime(result) : result
    }

    /// `x·y + addend + carry` as (high, low). Cannot overflow 128 bits.
    private static func multiplyAdd(_ x: UInt64, _ y: UInt64, _ addend: UInt64, _ carry: UInt64) -> (UInt64, UInt64) {
        let (high, low) = x.multipliedFullWidth(by: y)
        let (sum1, overflow1) = low.addingReportingOverflow(addend)
        let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
        return (high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0), sum2)
    }

    private static func addModulo(_ a: Number, _ b: Number) -> Number {
        var words = [UInt64](repeating: 0, count: limbs)
        var carry = false
        for i in 0 ..< limbs {
            let (sum1, overflow1) = a.words[i].addingReportingOverflow(b.words[i])
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry ? 1 : 0)
            words[i] = sum2
            carry = overflow1 || overflow2
        }
        let sum = Number(words: words)
        return carry || !isBelowPrime(sum) ? subtractPrime(sum) : sum
    }

    private static func isBelowPrime(_ value: Number) -> Bool {
        for i in stride(from: limbs - 1, through: 0, by: -1) where value.words[i] != prime.words[i] {
            return value.words[i] < prime.words[i]
        }
        return false
    }

    /// `value - p`, wrapping modulo 2⁷⁶⁸ — which is exactly right when the value
    /// carried out of the top limb.
    private static func subtractPrime(_ value: Number) -> Number {
        var words = value.words
        var borrow = false
        for i in 0 ..< limbs {
            let (diff1, overflow1) = words[i].subtractingReportingOverflow(prime.words[i])
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow ? 1 : 0)
            words[i] = diff2
            borrow = overflow1 || overflow2
        }
        return Number(words: words)
    }
}
