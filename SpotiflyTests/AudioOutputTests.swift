//
//  AudioOutputTests.swift
//  SpotiflyTests
//
//  The stream header the audio output serves
//

import Foundation
@testable import Spotifly
import Testing

/// The CAF header `PCMStream` serves ahead of the PCM: what AVPlayer parses to play the stream.
/// Big-endian throughout, 68 bytes, as Apple's CAF specification lays the chunks out.
struct PCMStreamHeaderTests {
    private func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int, in data: Data) -> T {
        data[offset ..< offset + MemoryLayout<T>.size].reduce(T(0)) { $0 << 8 | T($1) }
    }

    @Test func `the header describes interleaved Float32 stereo at 44.1 kHz`() {
        let header = PCMStream.cafHeader(dataBytes: 8000)

        #expect(header.count == 68)
        #expect(String(decoding: header[0 ..< 4], as: UTF8.self) == "caff")
        #expect(String(decoding: header[8 ..< 12], as: UTF8.self) == "desc")
        #expect(bigEndian(Int64.self, at: 12, in: header) == 32)
        #expect(Double(bitPattern: bigEndian(UInt64.self, at: 20, in: header)) == 44100)
        #expect(String(decoding: header[28 ..< 32], as: UTF8.self) == "lpcm")
        #expect(bigEndian(UInt32.self, at: 32, in: header) == 3) // float, little-endian samples
        #expect(bigEndian(UInt32.self, at: 36, in: header) == 8) // bytes per frame
        #expect(bigEndian(UInt32.self, at: 44, in: header) == 2) // channels
        #expect(bigEndian(UInt32.self, at: 48, in: header) == 32) // bits per channel
        #expect(String(decoding: header[52 ..< 56], as: UTF8.self) == "data")
        #expect(bigEndian(Int64.self, at: 56, in: header) == 8004) // the edit count is in the chunk
    }
}
