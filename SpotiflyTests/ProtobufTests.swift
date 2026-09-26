//
//  ProtobufTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// The shared wire-format helpers, checked against encodings from the protobuf spec
/// (https://protobuf.dev/programming-guides/encoding/).
struct ProtobufTests {
    @Test func `varints match the spec's examples`() {
        // "150" in field 1 is the spec's first worked example: 08 96 01.
        #expect(ProtobufWriter.message { $0.varint(field: 1, 150) }.hexString == "089601")
        // A negative int is sign-extended to ten bytes.
        #expect(ProtobufWriter.message { $0.varint(field: 1, Int32(-2)) }.hexString == "08feffffffffffffffff01")
        // Large unsigned values keep their bits.
        #expect(ProtobufWriter.message { $0.varint(field: 1, UInt64.max) }.hexString == "08ffffffffffffffffff01")
    }

    @Test func `strings, nested messages and doubles`() {
        // The spec's "testing" string in field 2: 12 07 74 65 73 74 69 6e 67.
        #expect(ProtobufWriter.message { $0.string(field: 2, "testing") }.hexString == "120774657374696e67")
        #expect(ProtobufWriter.message { $0.message(field: 3) { $0.varint(field: 1, 150) } }.hexString == "1a03089601")
        #expect(ProtobufWriter.message { $0.double(field: 9, 1.0) }.hexString == "49000000000000f03f")
        // Field numbers past 15 take a two-byte tag.
        #expect(ProtobufWriter.message { $0.bool(field: 16, true) }.hexString == "800101")
    }

    @Test func `a map is written in key order, one entry message per key`() {
        let data = ProtobufWriter.message { $0.map(field: 3, ["b": "2", "a": "1"]) }

        // 1a 06 { 0a 01 "a", 12 01 "1" }, then the same for "b".
        #expect(data.hexString == "1a060a0161120131" + "1a060a0162120132")
        let entries = ProtobufReader.fields(in: data).map(\.mapEntry)
        #expect(entries.map(\.key) == ["a", "b"])
        #expect(entries.map(\.value) == ["1", "2"])
    }

    @Test func `reading gives back what was written`() {
        let data = ProtobufWriter.message {
            $0.varint(field: 1, Int64(-5))
            $0.string(field: 2, "spotify:track:abc")
            $0.message(field: 3) {
                $0.string(field: 1, "key")
                $0.string(field: 2, "value")
            }
            $0.double(field: 9, 1.5)
            $0.bool(field: 25, true)
        }

        let fields = ProtobufReader.fields(in: data)

        #expect(fields.map(\.number) == [1, 2, 3, 9, 25])
        #expect(fields[0].int64 == -5)
        #expect(fields[1].string == "spotify:track:abc")
        let entry = fields[2].mapEntry
        #expect(entry.key == "key")
        #expect(entry.value == "value")
        #expect(fields[3].double == 1.5)
        #expect(fields[4].bool)
    }

    @Test func `a fixed32 field is skipped cleanly`() {
        // Field 4, wire type 5, then field 1 = 1.
        let fields = ProtobufReader.fields(in: Data([0x25, 1, 2, 3, 4, 0x08, 0x01]))

        #expect(fields.map(\.number) == [4, 1])
        #expect(fields[1].value == 1)
    }

    @Test func `a truncated field ends the message instead of reading past it`() {
        let fields = ProtobufReader.fields(in: Data([0x08, 0x01, 0x12, 0x05, 0x61]))

        #expect(fields.map(\.number) == [1])
    }

    /// A reader handed a slice must not assume its indices start at zero.
    @Test func `a data slice reads like a fresh copy`() {
        let whole = Data([0xFF, 0xFF, 0x08, 0x2A])
        let fields = ProtobufReader.fields(in: whole[2...])

        #expect(fields.count == 1)
        #expect(fields[0].value == 42)
    }
}
