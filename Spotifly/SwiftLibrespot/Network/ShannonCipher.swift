//
//  ShannonCipher.swift
//  SwiftLibrespot
//
//  Shannon stream cipher implementation (ported from devgianlu/shannon)
//  Used for encrypting/decrypting Spotify AP communication after handshake
//

import Foundation

/// Shannon stream cipher for Spotify protocol encryption
/// Based on the reference implementation from devgianlu/shannon
public final class ShannonCipher: @unchecked Sendable {
    // MARK: - Constants

    private nonisolated static let n: Int = 16
    private nonisolated static let initKonst: UInt32 = 0x6996_C53A
    private nonisolated static let keyP: Int = 13

    // MARK: - State

    private nonisolated(unsafe) var r: [UInt32]
    private nonisolated(unsafe) var crc: [UInt32]
    private nonisolated(unsafe) var initR: [UInt32]
    private nonisolated(unsafe) var konst: UInt32
    private nonisolated(unsafe) var sbuf: UInt32
    private nonisolated(unsafe) var mbuf: UInt32
    private nonisolated(unsafe) var nbuf: Int

    // MARK: - Initialization

    /// Create a new Shannon cipher with the given key
    public nonisolated init(key: Data) {
        r = [UInt32](repeating: 0, count: Self.n)
        crc = [UInt32](repeating: 0, count: Self.n)
        initR = [UInt32](repeating: 0, count: Self.n)
        konst = Self.initKonst
        sbuf = 0
        mbuf = 0
        nbuf = 0

        // Initialize r with Fibonacci sequence
        r[0] = 1
        r[1] = 1
        for i in 2 ..< Self.n {
            r[i] = r[i - 1] &+ r[i - 2]
        }

        loadKey(key)
        genKonst()
        saveState()
    }

    // MARK: - Nonce

    /// Set nonce for this cipher instance
    public nonisolated func nonce(_ nonceData: Data) {
        reloadState()
        konst = Self.initKonst
        loadKey(nonceData)
        genKonst()
        nbuf = 0
    }

    /// Set nonce from a 32-bit counter (big-endian)
    public nonisolated func nonceU32(_ n: UInt32) {
        var data = Data(count: 4)
        data[0] = UInt8((n >> 24) & 0xFF)
        data[1] = UInt8((n >> 16) & 0xFF)
        data[2] = UInt8((n >> 8) & 0xFF)
        data[3] = UInt8(n & 0xFF)
        nonce(data)
    }

    // MARK: - Encrypt/Decrypt

    /// Encrypt data in place
    public nonisolated func encrypt(_ data: inout Data) {
        process(
            &data,
            fullWord: { cipher, word in
                cipher.macFunc(word.pointee)
                word.pointee ^= cipher.sbuf
            },
            partial: { cipher, byte in
                cipher.mbuf ^= UInt32(byte.pointee) << (32 - cipher.nbuf)
                byte.pointee ^= UInt8((cipher.sbuf >> (32 - cipher.nbuf)) & 0xFF)
            },
        )
    }

    /// Decrypt data in place
    public nonisolated func decrypt(_ data: inout Data) {
        process(
            &data,
            fullWord: { cipher, word in
                word.pointee ^= cipher.sbuf
                cipher.macFunc(word.pointee)
            },
            partial: { cipher, byte in
                byte.pointee ^= UInt8((cipher.sbuf >> (32 - cipher.nbuf)) & 0xFF)
                cipher.mbuf ^= UInt32(byte.pointee) << (32 - cipher.nbuf)
            },
        )
    }

    /// Generate MAC and finalize
    public nonisolated func finish(_ macLen: Int) -> Data {
        // Handle any buffered bytes
        if nbuf != 0 {
            macFunc(mbuf)
        }

        // Generate MAC
        cycle()
        addKey(Self.initKonst)
        var crcSave = crc

        for _ in 0 ..< Self.n {
            crcFunc(0)
        }

        for i in 0 ..< Self.n {
            crc[i] ^= crcSave[i]
        }

        crcSave = crc

        for _ in 0 ..< Self.n {
            cycle()
        }

        for i in 0 ..< Self.n {
            crc[i] ^= r[i]
        }

        // Extract MAC bytes
        var mac = Data(count: macLen)
        nbuf = 0
        for i in 0 ..< macLen {
            if nbuf == 0 {
                crc[0] ^= crc[2] ^ crc[15] ^ 1
                for j in 1 ..< Self.n {
                    crc[j - 1] = crc[j]
                }
                crc[Self.n - 1] = sbuf
                sbuf = crc[0] ^ crcSave[0]
                nbuf = 32
            }
            mac[i] = UInt8((sbuf >> (32 - nbuf)) & 0xFF)
            nbuf -= 8
        }

        return mac
    }

    /// Check if MAC matches expected value
    public nonisolated func checkMac(_ expected: Data) -> Error? {
        let computed = finish(expected.count)
        if computed != expected {
            return LibrespotError.encryptionError("MAC mismatch")
        }
        return nil
    }

    // MARK: - Internal State Management

    private nonisolated func saveState() {
        for i in 0 ..< Self.n {
            initR[i] = r[i]
        }
    }

    private nonisolated func reloadState() {
        for i in 0 ..< Self.n {
            r[i] = initR[i]
        }
    }

    private nonisolated func genKonst() {
        konst = r[0]
    }

    private nonisolated func loadKey(_ key: Data) {
        // Fold key into state
        var offset = 0
        while offset < key.count {
            var word: UInt32 = 0
            for i in 0 ..< 4 {
                if offset + i < key.count {
                    word |= UInt32(key[offset + i]) << (i * 8)
                }
            }
            r[Self.keyP] ^= word
            cycle()
            offset += 4
        }

        // Fold in key length
        r[Self.keyP] ^= UInt32(key.count)
        cycle()

        // Save CRC state
        for i in 0 ..< Self.n {
            crc[i] = r[i]
        }

        // Diffuse
        diffuse()

        // XOR with CRC to make irreversible
        for i in 0 ..< Self.n {
            r[i] ^= crc[i]
        }
    }

    private nonisolated func diffuse() {
        for _ in 0 ..< Self.n {
            cycle()
        }
    }

    private nonisolated func addKey(_ k: UInt32) {
        r[Self.keyP] ^= k
    }

    // MARK: - Core Cycle

    private nonisolated func cycle() {
        // Nonlinear feedback function
        var t = r[12] ^ r[13] ^ konst
        t = sbox1(t) ^ rotl(r[0], 1)

        // Shift register
        for i in 1 ..< Self.n {
            r[i - 1] = r[i]
        }
        r[Self.n - 1] = t

        t = sbox2(r[2] ^ r[15])
        r[0] ^= t
        sbuf = t ^ r[8] ^ r[12]
    }

    // MARK: - S-boxes

    private nonisolated func sbox1(_ w: UInt32) -> UInt32 {
        var x = w
        x = x ^ (rotl(x, 5) | rotl(x, 7))
        x = x ^ (rotl(x, 19) | rotl(x, 22))
        return x
    }

    private nonisolated func sbox2(_ w: UInt32) -> UInt32 {
        var x = w
        x = x ^ (rotl(x, 7) | rotl(x, 22))
        x = x ^ (rotl(x, 5) | rotl(x, 19))
        return x
    }

    private nonisolated func rotl(_ value: UInt32, _ shift: Int) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    // MARK: - MAC Functions

    private nonisolated func crcFunc(_ i: UInt32) {
        let t = crc[0] ^ crc[2] ^ crc[15] ^ i
        for j in 1 ..< Self.n {
            crc[j - 1] = crc[j]
        }
        crc[Self.n - 1] = t
    }

    private nonisolated func macFunc(_ i: UInt32) {
        crcFunc(i)
        r[Self.keyP] ^= i
    }

    // MARK: - Process Buffer

    private nonisolated func process(
        _ buf: inout Data,
        fullWord: (ShannonCipher, UnsafeMutablePointer<UInt32>) -> Void,
        partial: (ShannonCipher, UnsafeMutablePointer<UInt8>) -> Void,
    ) {
        var offset = 0

        // Handle previously buffered bytes
        if nbuf != 0 {
            while nbuf > 0, offset < buf.count {
                buf.withUnsafeMutableBytes { ptr in
                    partial(self, ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
                }
                nbuf -= 8
                offset += 1
            }

            if nbuf != 0 {
                return
            }

            macFunc(mbuf)
        }

        // Handle whole words
        while offset + 4 <= buf.count {
            cycle()
            var word = readLittleEndian(buf, offset: offset)
            withUnsafeMutablePointer(to: &word) { ptr in
                fullWord(self, ptr)
            }
            writeLittleEndian(&buf, offset: offset, value: word)
            offset += 4
        }

        // Handle trailing bytes
        if offset < buf.count {
            cycle()
            mbuf = 0
            nbuf = 32
            while offset < buf.count {
                buf.withUnsafeMutableBytes { ptr in
                    partial(self, ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
                }
                nbuf -= 8
                offset += 1
            }
        }
    }

    // MARK: - Helpers

    private nonisolated func readLittleEndian(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private nonisolated func writeLittleEndian(_ data: inout Data, offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

/// Thread-safe cipher pair for send/receive
public actor CipherPair {
    private let sendCipher: ShannonCipher
    private let recvCipher: ShannonCipher

    public init(sendKey: Data, recvKey: Data) {
        sendCipher = ShannonCipher(key: sendKey)
        recvCipher = ShannonCipher(key: recvKey)
    }

    /// Encrypt data for sending
    public func encrypt(_ data: Data, nonce: UInt32) -> (encrypted: Data, mac: Data) {
        sendCipher.nonceU32(nonce)
        var encrypted = data
        sendCipher.encrypt(&encrypted)
        let mac = sendCipher.finish(4)
        return (encrypted, mac)
    }

    /// Decrypt received data
    public func decrypt(_ data: Data, nonce: UInt32) -> Data {
        recvCipher.nonceU32(nonce)
        var decrypted = data
        recvCipher.decrypt(&decrypted)
        _ = recvCipher.finish(4) // Consume MAC state
        return decrypted
    }

    /// Verify MAC matches expected
    public func checkMac(_ expectedMac: Data, nonce: UInt32) -> Error? {
        recvCipher.nonceU32(nonce)
        return recvCipher.checkMac(expectedMac)
    }
}
