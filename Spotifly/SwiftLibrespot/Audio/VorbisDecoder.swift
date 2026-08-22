//
//  VorbisDecoder.swift
//  SwiftLibrespot
//
//  Swift wrapper over the vendored libvorbisfile for decoding Spotify's
//  Ogg Vorbis audio streams held in memory.
//

import CVorbis
import Foundation

/// Decodes a decrypted Ogg Vorbis stream into interleaved Float32 PCM.
///
/// The decrypted file is held in memory for the lifetime of the decoder (a
/// typical track is a few megabytes), which makes seeking a cheap
/// `ov_pcm_seek` against the buffered stream rather than a re-download.
///
/// Not thread-safe by design: ownership transfers to exactly one decode task
/// at a time (see AudioPipeline). Declared `@unchecked Sendable` so that
/// hand-off can cross an actor boundary without copying.
final nonisolated class VorbisDecoder: @unchecked Sendable {
    /// Stream format as it came off the wire. Spotify serves stereo 44.1 kHz,
    /// but nothing here assumes that — callers configure their renderers from
    /// these values.
    struct Format: Equatable {
        let sampleRate: Int
        let channels: Int

        var frameSampleCount: Int {
            channels
        }
    }

    /// Total decoded frames in the stream, or -1 when unknown (unseekable).
    private(set) var totalFrames: Int64

    let format: Format

    private var file = OggVorbis_File()
    private(set) var isOpen = false

    /// Heap context shared with the C read callbacks.
    private final nonisolated class Source {
        let bytes: [UInt8]
        /// Read position within `bytes`. Only touched from the callbacks, and
        /// libvorbisfile serializes its calls into a single stream.
        var offset: Int = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }
    }

    private let source: Source

    // MARK: - Lifecycle

    /// Opens a decrypted Ogg Vorbis stream. Throws when the data does not parse,
    /// which after decryption almost always means wrong key or wrong byte offset —
    /// garbage where the first Ogg page should be, not a corrupt tail.
    init(data: Data) throws {
        source = Source(data)

        var error: Int32 = OV_EBADHEADER
        var openedFormat: Format?
        var openedTotal: Int64 = -1

        source.offset = 0
        let result = ov_open_callbacks(Unmanaged.passUnretained(source).toOpaque(), &file, nil, 0, Self.callbacks)
        if result == 0 {
            isOpen = true
            if let info = ov_info(&file, -1) {
                openedFormat = Format(sampleRate: Int(info.pointee.rate), channels: Int(info.pointee.channels))
            }
            openedTotal = ov_pcm_total(&file, -1)
        } else {
            error = result
        }

        guard let format = openedFormat else {
            // On open failure the stream was never successfully opened, so there
            // is nothing to ov_clear — the docs are explicit about that.
            throw LibrespotError.decodingFailed("not an Ogg Vorbis stream (libvorbisfile error \(error))")
        }
        self.format = format
        totalFrames = openedTotal
    }

    deinit {
        close()
    }

    func close() {
        guard isOpen else { return }
        ov_clear(&file)
        isOpen = false
    }

    // MARK: - Reading

    /// Reads up to `maxFrames` decoded frames into `output`, interleaved,
    /// returning the number of frames written. Returns 0 at end of stream.
    ///
    /// `output` must hold at least `maxFrames * format.channels` floats.
    func read(into output: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        guard isOpen, maxFrames > 0 else { return 0 }

        var bitstream: Int32 = 0
        var channelsBuffer: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
        var written = 0

        while written < maxFrames {
            let frames = ov_read_float(&file, &channelsBuffer, Int32(maxFrames - written), &bitstream)
            if frames == 0 {
                break // end of stream
            }
            if frames == -3 /* OV_HOLE */ || frames == -137 /* OV_EBADLINK */ {
                // Recoverable: the decoder resynced or we seeked across a
                // logical bitstream boundary. Keep reading.
                continue
            }
            if frames < 0 {
                debugLog("VorbisDecoder", "read error \(frames)")
                break
            }

            guard let channels = channelsBuffer else { break }
            let channelCount = format.channels
            let frameCount = Int(frames)

            for frame in 0 ..< frameCount {
                for channel in 0 ..< channelCount {
                    output[written + frame * channelCount + channel] = channels[channel]![frame]
                }
            }

            written += frameCount
        }

        return written
    }

    /// Reads up to `maxFrames` frames, allocating the destination array.
    func read(maxFrames: Int) -> ([Float], framesRead: Int)? {
        var output = [Float](repeating: 0, count: maxFrames * max(1, format.channels))
        let frames = read(into: &output, maxFrames: maxFrames)
        guard frames > 0 else { return nil }
        return (output, frames)
    }

    // MARK: - Positioning

    /// Current decode position in frames.
    var currentFrame: Int64 {
        isOpen ? ov_pcm_tell(&file) : 0
    }

    /// Seeks to an absolute frame offset. Cheap because the whole stream is in
    /// memory. Returns false when the stream cannot be seeked.
    @discardableResult
    func seek(toFrame frame: Int64) -> Bool {
        guard isOpen else { return false }
        return ov_pcm_seek(&file, frame) == 0
    }

    // MARK: - C callbacks

    private static let callbacks = ov_callbacks(
        read_func: { buffer, size, count, datasource in
            guard let datasource, let buffer else { return 0 }
            let source = Unmanaged<Source>.fromOpaque(datasource).takeUnretainedValue()
            let request = size * count
            let available = source.bytes.count - source.offset
            let copied = min(request, available)

            if copied > 0 {
                source.bytes.withUnsafeBytes { raw in
                    buffer.copyMemory(
                        from: raw.baseAddress!.advanced(by: source.offset),
                        byteCount: copied,
                    )
                }
                source.offset += copied
            }
            return copied / size
        },
        seek_func: { datasource, offset, whence in
            guard let datasource else { return -1 }
            let source = Unmanaged<Source>.fromOpaque(datasource).takeUnretainedValue()

            let target: Int
            switch whence {
            case 0: target = Int(offset) // SEEK_SET
            case 1: target = source.offset + Int(offset) // SEEK_CUR
            case 2: target = source.bytes.count + Int(offset) // SEEK_END
            default: return -1
            }

            guard target >= 0, target <= source.bytes.count else { return -1 }
            source.offset = target
            return 0
        },
        close_func: { _ in 0 }, // Swift owns the lifetime
        tell_func: { datasource in
            guard let datasource else { return -1 }
            let source = Unmanaged<Source>.fromOpaque(datasource).takeUnretainedValue()
            return source.offset // long → Swift Int on LP64
        },
    )
}
