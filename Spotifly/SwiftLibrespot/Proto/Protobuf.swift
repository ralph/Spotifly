//
//  Protobuf.swift
//  Spotifly
//
//  The protobuf wire format, for every message the app speaks: the accesspoint
//  handshake and login, connect-state, spclient metadata, and the client token.
//

import Foundation

/// Writes protobuf wire format.
///
/// Deliberately not a dependency. The messages this app encodes are small and few, and a
/// code-generation toolchain for them would be more machinery than the thing it encodes.
///
/// Nothing is left out implicitly: a field is on the wire exactly when a line writes it, so a
/// message reads top to bottom the way its bytes go out. Callers skip defaults themselves
/// where the peer cares.
nonisolated struct ProtobufWriter {
    private(set) var data = Data()

    /// Builds a message in one expression.
    static func message(_ body: (inout ProtobufWriter) -> Void) -> Data {
        var writer = ProtobufWriter()
        body(&writer)
        return writer.data
    }

    /// `int32`, `int64`, `uint32`, `uint64`, `bool` and enums. A negative value is
    /// sign-extended to ten bytes, as protobuf does for both signed widths.
    mutating func varint(field: Int, _ value: some BinaryInteger) {
        appendTag(field: field, wire: 0)
        appendVarint(UInt64(truncatingIfNeeded: Int64(truncatingIfNeeded: value)))
    }

    mutating func bool(field: Int, _ value: Bool) {
        varint(field: field, value ? 1 : 0)
    }

    mutating func string(field: Int, _ value: String) {
        bytes(field: field, Data(value.utf8))
    }

    mutating func bytes(field: Int, _ value: Data) {
        appendTag(field: field, wire: 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// Nests a submessage, which the wire format expresses as length-prefixed bytes.
    mutating func message(field: Int, _ body: (inout ProtobufWriter) -> Void) {
        bytes(field: field, Self.message(body))
    }

    /// A `map<string, string>`: one entry message per key, key in field 1 and value in
    /// field 2. Entries go out in key order, so the bytes do not depend on how the
    /// dictionary happens to iterate.
    mutating func map(field: Int, _ map: [String: String]) {
        for (key, value) in map.sorted(by: { $0.key < $1.key }) {
            message(field: field) {
                $0.string(field: 1, key)
                $0.string(field: 2, value)
            }
        }
    }

    mutating func double(field: Int, _ value: Double) {
        appendTag(field: field, wire: 1)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private mutating func appendTag(field: Int, wire: UInt64) {
        appendVarint(UInt64(field) << 3 | wire)
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

/// One field of a received message.
///
/// Readers switch on `number` and take the view they expect; a field of another wire type
/// reads as zero or empty rather than failing the message.
nonisolated struct ProtobufField {
    let number: Int
    /// 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32.
    let wireType: Int
    /// A varint, or the raw little-endian bits of a fixed-width field.
    let value: UInt64
    /// A length-delimited payload; empty for every other wire type.
    let bytes: Data

    var bool: Bool {
        value != 0
    }

    var int64: Int64 {
        Int64(bitPattern: value)
    }

    /// A `sint32`/`sint64`, which the wire format zigzag-encodes: read as a plain
    /// varint it comes out doubled.
    var sint64: Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    var string: String {
        String(decoding: bytes, as: UTF8.self)
    }

    var double: Double {
        Double(bitPattern: value)
    }

    /// The fields of a nested message.
    var fields: [ProtobufField] {
        ProtobufReader.fields(in: bytes)
    }

    /// A `map<string, string>` entry, which the wire format writes as a message with the key
    /// in field 1 and the value in field 2.
    var mapEntry: (key: String, value: String) {
        let fields = fields
        return (
            fields.last { $0.number == 1 }?.string ?? "",
            fields.last { $0.number == 2 }?.string ?? "",
        )
    }
}

extension [ProtobufField] {
    /// The field with this number, or the last of them if it repeats — which is how protobuf
    /// reads a singular field that arrives twice.
    nonisolated func last(_ number: Int) -> ProtobufField? {
        last { $0.number == number }
    }
}

/// Reads protobuf wire format.
///
/// Unknown fields are skipped rather than rejected — Spotify adds fields to these messages
/// without warning, and a reader that insists on knowing every one of them would break on a
/// server change that costs us nothing. Malformed input ends the message where it breaks: a
/// truncated message and a finished one are the same thing to every caller here.
nonisolated enum ProtobufReader {
    /// Every field of a message, in wire order.
    static func fields(in data: Data) -> [ProtobufField] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [ProtobufField] = []

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
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

        func readFixed(_ width: Int) -> UInt64? {
            guard bytes.count - index >= width else { return nil }
            var result: UInt64 = 0
            for offset in 0 ..< width {
                result |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
            }
            index += width
            return result
        }

        while let tag = readVarint() {
            let number = Int(tag >> 3)
            guard number > 0 else { break }

            switch tag & 0x07 {
            case 0:
                guard let value = readVarint() else { return fields }
                fields.append(ProtobufField(number: number, wireType: 0, value: value, bytes: Data()))
            case 1:
                guard let value = readFixed(8) else { return fields }
                fields.append(ProtobufField(number: number, wireType: 1, value: value, bytes: Data()))
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return fields }
                let end = index + Int(length)
                fields.append(ProtobufField(number: number, wireType: 2, value: 0, bytes: Data(bytes[index ..< end])))
                index = end
            case 5:
                guard let value = readFixed(4) else { return fields }
                fields.append(ProtobufField(number: number, wireType: 5, value: value, bytes: Data()))
            default:
                // Groups (3, 4) are long gone from proto3 and nothing here emits them.
                return fields
            }
        }
        return fields
    }

    /// The bytes of the first occurrence of a length-delimited field, if present.
    static func firstBytes(field wanted: Int, in data: Data) -> Data? {
        fields(in: data).first { $0.number == wanted && $0.wireType == 2 }?.bytes
    }

    /// The value of the first occurrence of a varint field, if present.
    static func firstVarint(field wanted: Int, in data: Data) -> UInt64? {
        fields(in: data).first { $0.number == wanted && $0.wireType == 0 }?.value
    }

    /// The UTF-8 contents of the first occurrence of a string field, if present.
    static func firstString(field wanted: Int, in data: Data) -> String? {
        guard let payload = firstBytes(field: wanted, in: data) else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}
