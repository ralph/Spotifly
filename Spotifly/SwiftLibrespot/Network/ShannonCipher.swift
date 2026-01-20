//
//  ShannonCipher.swift
//  SwiftLibrespot
//
//  Shannon stream cipher implementation (ported from go-librespot)
//  Used for encrypting/decrypting Spotify AP communication after handshake
//

import Foundation

/// Shannon stream cipher for Spotify protocol encryption
/// Based on the reference implementation from go-librespot
public final class ShannonCipher: @unchecked Sendable {
    // MARK: - Constants

    private nonisolated(unsafe) static let n = 16
    private nonisolated(unsafe) static let fold = n
    private nonisolated(unsafe) static let initKonst: UInt32 = 0x6996_C53A
    private nonisolated(unsafe) static let keyP: Int = 13
    private nonisolated(unsafe) static let keyNonce: UInt32 = 0x4556_6F7A // "EVoz"

    // MARK: - State

    private nonisolated(unsafe) var r: [UInt32]
    private nonisolated(unsafe) var cng: [UInt32]
    private nonisolated(unsafe) var sbuf: [UInt32]
    private nonisolated(unsafe) var konst: UInt32
    private nonisolated(unsafe) var mbuf: UInt32
    private nonisolated(unsafe) var nbuf: Int

    // MARK: - Nonce Counter

    private nonisolated(unsafe) var nonce: UInt32 = 0

    // MARK: - Initialization

    public nonisolated init() {
        r = [UInt32](repeating: 0, count: Self.n)
        cng = [UInt32](repeating: 0, count: Self.n)
        sbuf = [UInt32](repeating: 0, count: Self.n)
        konst = Self.initKonst
        mbuf = 0
        nbuf = 0
    }

    /// Initialize cipher with a key
    public nonisolated func key(_ key: Data) {
        var extra = [UInt32](repeating: 0, count: Self.n)
        let keyWords = key.count / 4

        // Load key into state
        for i in 0 ..< keyWords {
            let offset = i * 4
            r[i] = UInt32(key[offset]) |
                (UInt32(key[offset + 1]) << 8) |
                (UInt32(key[offset + 2]) << 16) |
                (UInt32(key[offset + 3]) << 24)
        }

        // Key scheduling
        for _ in 0 ..< Self.n {
            cycle()
        }

        // Save state
        for i in 0 ..< Self.n {
            extra[i] = r[i]
        }

        // More key scheduling
        for _ in 0 ..< Self.n {
            cycle()
        }

        // XOR with saved state
        for i in 0 ..< Self.n {
            r[i] ^= extra[i]
        }
    }

    /// Set nonce for this cipher instance
    public nonisolated func setNonce(_ nonceData: Data) {
        // Load nonce into state
        key(nonceData)

        // Additional diffusion
        for _ in 0 ..< Self.n {
            cycle()
        }

        konst = Self.initKonst
    }

    /// Set nonce from a 32-bit counter
    public nonisolated func setNonce(_ nonce: UInt32) {
        var nonceData = Data(count: 4)
        nonceData[0] = UInt8(nonce >> 24)
        nonceData[1] = UInt8((nonce >> 16) & 0xFF)
        nonceData[2] = UInt8((nonce >> 8) & 0xFF)
        nonceData[3] = UInt8(nonce & 0xFF)
        setNonce(nonceData)
    }

    /// Encrypt data in place
    public nonisolated func encrypt(_ data: inout Data) {
        for i in 0 ..< data.count {
            if nbuf == 0 {
                cycle()
                nbuf = 4
            }

            data[i] ^= UInt8(sbuf[0] & 0xFF)
            sbuf[0] >>= 8
            nbuf -= 1
        }
    }

    /// Decrypt data in place
    public nonisolated func decrypt(_ data: inout Data) {
        // Shannon is symmetric - encrypt and decrypt are the same
        encrypt(&data)
    }

    /// Generate MAC for the data
    public nonisolated func finish(_ macLen: Int) -> Data {
        // Finalize the state
        cycle()
        addKey(Self.initKonst)
        nbuf = 0

        // Generate MAC
        var mac = Data(count: macLen)
        for i in 0 ..< macLen {
            if nbuf == 0 {
                cycle()
                nbuf = 4
            }
            mac[i] = UInt8(sbuf[0] & 0xFF)
            sbuf[0] >>= 8
            nbuf -= 1
        }

        return mac
    }

    /// Increment nonce and set it
    public nonisolated func incrementNonce() {
        nonce = nonce &+ 1
        setNonce(nonce)
    }

    // MARK: - Internal

    private nonisolated func cycle() {
        // Shift register
        let t = r[12] ^ r[13] ^ konst
        konst = r[0]

        for i in 0 ..< (Self.n - 1) {
            r[i] = r[i + 1]
        }
        r[Self.n - 1] = t

        // Non-linear update
        let t2 = r[0]
        sbuf[0] = sbox(t2)

        for i in 1 ..< Self.n {
            cng[i] = r[i] ^ sbuf[i - 1]
        }
        cng[0] = t2 ^ sbuf[Self.n - 1]

        for i in 0 ..< Self.n {
            r[i] = cng[i]
        }
    }

    private nonisolated func sbox(_ input: UInt32) -> UInt32 {
        // Shannon S-box function
        var w = input
        w ^= rotl(w, 5) | rotl(w, 7)
        w ^= rotl(w, 19) | rotl(w, 22)
        return w
    }

    private nonisolated func rotl(_ value: UInt32, _ shift: Int) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private nonisolated func addKey(_ k: UInt32) {
        r[Self.keyP] ^= k
    }
}

/// Thread-safe cipher pair for send/receive
public actor CipherPair {
    private let sendCipher: ShannonCipher
    private let recvCipher: ShannonCipher

    public init(sendKey: Data, recvKey: Data) {
        sendCipher = ShannonCipher()
        sendCipher.key(sendKey)

        recvCipher = ShannonCipher()
        recvCipher.key(recvKey)
    }

    /// Encrypt data for sending
    public func encrypt(_ data: Data, nonce: UInt32) -> (encrypted: Data, mac: Data) {
        sendCipher.setNonce(nonce)
        var encrypted = data
        sendCipher.encrypt(&encrypted)
        let mac = sendCipher.finish(4)
        return (encrypted, mac)
    }

    /// Decrypt received data
    public func decrypt(_ data: Data, nonce: UInt32) -> Data {
        recvCipher.setNonce(nonce)
        var decrypted = data
        recvCipher.decrypt(&decrypted)
        _ = recvCipher.finish(4) // Consume MAC state
        return decrypted
    }

    /// Verify MAC matches expected
    public func verifyMAC(_ data: Data, expectedMAC: Data, nonce: UInt32) -> Bool {
        recvCipher.setNonce(nonce)
        var copy = data
        recvCipher.decrypt(&copy)
        let computedMAC = recvCipher.finish(expectedMAC.count)
        return computedMAC == expectedMAC
    }
}
