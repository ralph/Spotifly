//
//  Protobuf.swift
//  Spotifly
//
//  Just enough protobuf for the handful of messages Spotify's own APIs speak.
//

import Foundation

/// Writes protobuf wire format.
///
/// Deliberately not a dependency. The messages this app encodes are tiny — the client-token
/// request is four scalar fields inside three nested messages — and a code-generation
/// toolchain for that would be more machinery than the thing it encodes. If the protobuf
/// surface grows past the spclient responses, revisit.
nonisolated struct ProtobufWriter {
    private(set) var data = Data()

    /// Wire types. Only these two appear in anything Spotifly sends.
    private enum WireType: UInt64 {
        case varint = 0
        case lengthDelimited = 2
    }

    mutating func varint(field: Int, _ value: UInt64) {
        appendTag(field: field, wire: .varint)
        appendVarint(value)
    }

    mutating func string(field: Int, _ value: String) {
        bytes(field: field, Data(value.utf8))
    }

    mutating func bytes(field: Int, _ value: Data) {
        appendTag(field: field, wire: .lengthDelimited)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// Nests a submessage, which the wire format expresses as length-prefixed bytes.
    mutating func message(field: Int, _ body: (inout ProtobufWriter) -> Void) {
        var nested = ProtobufWriter()
        body(&nested)
        bytes(field: field, nested.data)
    }

    private mutating func appendTag(field: Int, wire: WireType) {
        appendVarint(UInt64(field) << 3 | wire.rawValue)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remaining != 0
    }
}

/// Reads protobuf wire format, field by field.
///
/// Unknown fields are skipped rather than rejected — Spotify adds fields to these messages
/// without warning, and a reader that insists on knowing every one of them would break on a
/// server change that costs us nothing.
nonisolated struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    /// The next field, or nil at the end. Returns nil on malformed input too: a truncated
    /// message and a finished one are the same thing to every caller here.
    mutating func next() -> (field: Int, value: Value)? {
        guard let tag = readVarint() else { return nil }

        let field = Int(tag >> 3)
        guard field > 0 else { return nil }

        switch tag & 0x07 {
        case 0:
            guard let value = readVarint() else { return nil }
            return (field, .varint(value))
        case 2:
            guard let length = readVarint(), let payload = read(Int(length)) else { return nil }
            return (field, .bytes(payload))
        case 1:
            guard read(8) != nil else { return nil }
            return next()
        case 5:
            guard read(4) != nil else { return nil }
            return next()
        default:
            // Groups (3, 4) are long gone from proto3 and nothing here emits them.
            return nil
        }
    }

    /// The bytes of the first occurrence of a length-delimited field, if present.
    static func firstBytes(field wanted: Int, in data: Data) -> Data? {
        var reader = ProtobufReader(data)
        while let (field, value) = reader.next() {
            if field == wanted, case let .bytes(payload) = value {
                return payload
            }
        }
        return nil
    }

    /// The value of the first occurrence of a varint field, if present.
    static func firstVarint(field wanted: Int, in data: Data) -> UInt64? {
        var reader = ProtobufReader(data)
        while let (field, value) = reader.next() {
            if field == wanted, case let .varint(number) = value {
                return number
            }
        }
        return nil
    }

    /// The UTF-8 contents of the first occurrence of a string field, if present.
    static func firstString(field wanted: Int, in data: Data) -> String? {
        guard let payload = firstBytes(field: wanted, in: data) else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)

            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
            if shift > 63 {
                return nil
            }
        }

        return nil
    }

    private mutating func read(_ count: Int) -> Data? {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else { return nil }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return data[index ..< end]
    }
}
