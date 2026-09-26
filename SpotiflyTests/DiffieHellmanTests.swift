//
//  DiffieHellmanTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// Known answers for the accesspoint key exchange, computed independently with Python's
/// arbitrary-precision `pow(base, exponent, prime)` over Spotify's 768-bit prime.
///
/// Private keys: `bytes(range(1, 96))` for ours and `bytes(range(200, 105, -1))` for the
/// server's, whose public key stands in for the one an accesspoint sends.
struct DiffieHellmanTests {
    private let privateKey = Data((1 ..< 96).map { UInt8($0) })

    @Test func `the public key matches the reference`() {
        let dh = DiffieHellman(privateKey: privateKey)

        #expect(dh.publicKeyBytes.hexString == "67fc0ff26b0890085f41ce5a9e85b60bd921034ba1f26c752b5c7b582b41aa68043655712a895c7d2b305c6b84dff1b5060056ab43b89934a56241e8a289a2ed4ea5c8fc941850cb36675b10b689e6827cd6cdc8237c6b72c381319ecba20f40")
    }

    @Test func `the shared secret matches the reference`() throws {
        let dh = DiffieHellman(privateKey: privateKey)
        let serverKey = try #require(Data(hex: "32a568e8a8adfb625ed72fa65c2a965262b37558fde09b6c58520f62b518e3c1158815401881999e04c42c5013774381cbee9382eab597e28f70d1c42864ffd3f2c3b4897085074fb857f20be4fc3085c3796041b1619bc4389c545f7d25336a"))

        #expect(dh.exchange(remotePublicKeyBytes: serverKey).hexString == "273bda206654f07b17bfa263a1abf6a4401705b38e8174523a704f80d4e56b3eff8101cbd8dd86ae02b02b16cde61a22101f45fbc5878ef2a042deda42414857684e1297ecd87602fd17f5d157a6978a4b77938b82cb2a0c86a1edd068ffd7a7")
    }

    /// librespot sends `to_bytes_be()`, which has no leading zero bytes, and the HMAC over
    /// the handshake covers these exact bytes — padding to 96 would fail the login.
    @Test func `a public key with a leading zero byte is sent without it`() throws {
        let key = try #require(Data(hex: "2002030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5e45a6bf"))
        let dh = DiffieHellman(privateKey: key)

        #expect(dh.publicKeyBytes.count == 95)
        #expect(dh.publicKeyBytes.hexString == "3827cfb08df5dbaa553b182bf433645bd81b327d1fad0b0e4c4695b3c91b8127b2c75750f18beaa663f558959cad966c824ffd72eb4148a0058cbe807552b418c01f1cfee11ab46e3b93cc8ec8baccd27978735b84a9478fe131e391f17016")
    }

    @Test func `two parties agree on the secret`() throws {
        let alice = try DiffieHellman()
        let bob = try DiffieHellman()

        #expect(alice.exchange(remotePublicKeyBytes: bob.publicKeyBytes) == bob.exchange(remotePublicKeyBytes: alice.publicKeyBytes))
    }
}

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
