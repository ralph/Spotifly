//
//  AudioStreamDecoder.swift
//  SwiftLibrespot
//
//  AudioToolbox-based audio decoder for MP3
//

import AudioToolbox
import AVFoundation
import Foundation

/// Audio file types supported for decoding
public enum AudioFileType: Sendable, Equatable {
    case mp3
    case oggVorbis
    case unknown

    public nonisolated static func == (lhs: AudioFileType, rhs: AudioFileType) -> Bool {
        switch (lhs, rhs) {
        case (.mp3, .mp3), (.oggVorbis, .oggVorbis), (.unknown, .unknown):
            true
        default:
            false
        }
    }

    nonisolated var audioFileTypeID: AudioFileTypeID {
        switch self {
        case .mp3:
            kAudioFileMP3Type
        case .oggVorbis:
            // OGG is not natively supported, would need custom decoder
            0
        case .unknown:
            0
        }
    }
}

/// Simple MP3 decoder using ExtAudioFile for file-based decoding
public final class SimpleAudioDecoder: @unchecked Sendable {
    private let outputFormat: AVAudioFormat

    public nonisolated init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false,
        )!
    }

    /// Decode complete audio data to PCM buffers
    public nonisolated func decode(data: Data, fileType: AudioFileType) throws -> [AVAudioPCMBuffer] {
        guard fileType == .mp3 else {
            throw LibrespotError.decodingFailed("Only MP3 is currently supported for decoding")
        }

        // Write to temp file for ExtAudioFile
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try data.write(to: tempURL)

        // Open with ExtAudioFile
        var extAudioFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(tempURL as CFURL, &extAudioFile)

        guard status == noErr, let audioFile = extAudioFile else {
            throw LibrespotError.decodingFailed("Failed to open audio file: \(status)")
        }

        defer {
            ExtAudioFileDispose(audioFile)
        }

        // Set output format
        var clientFormat = outputFormat.streamDescription.pointee
        status = ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat,
        )

        guard status == noErr else {
            throw LibrespotError.decodingFailed("Failed to set output format: \(status)")
        }

        // Get file length
        var fileLengthFrames: Int64 = 0
        var propSize = UInt32(MemoryLayout<Int64>.size)
        status = ExtAudioFileGetProperty(
            audioFile,
            kExtAudioFileProperty_FileLengthFrames,
            &propSize,
            &fileLengthFrames,
        )

        guard status == noErr else {
            throw LibrespotError.decodingFailed("Failed to get file length: \(status)")
        }

        debugLog("SimpleAudioDecoder", "Decoding \(fileLengthFrames) frames")

        // Read in chunks
        var buffers: [AVAudioPCMBuffer] = []
        let chunkFrames: AVAudioFrameCount = 8192
        var totalRead: Int64 = 0

        while totalRead < fileLengthFrames {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkFrames) else {
                throw LibrespotError.decodingFailed("Failed to create buffer")
            }

            // Create buffer list for stereo non-interleaved
            var bufferList = AudioBufferList()
            bufferList.mNumberBuffers = 2

            // We need to manually set up the buffer list for non-interleaved stereo
            let channelData = buffer.floatChannelData!

            // Use withUnsafeMutablePointer to set up the buffer list
            var audioBuffers = [AudioBuffer](repeating: AudioBuffer(), count: 2)
            audioBuffers[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: chunkFrames * 4,
                mData: channelData[0],
            )
            audioBuffers[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: chunkFrames * 4,
                mData: channelData[1],
            )

            var frameCount = chunkFrames

            // Create proper AudioBufferList for stereo non-interleaved
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }

            bufferListPtr.pointee.mNumberBuffers = 2

            withUnsafeMutablePointer(to: &bufferListPtr.pointee.mBuffers) { buffersPtr in
                let audioBufferPtr = buffersPtr
                audioBufferPtr[0] = audioBuffers[0]
                // Access second buffer through raw pointer arithmetic
                let secondBufferPtr = UnsafeMutableRawPointer(audioBufferPtr)
                    .advanced(by: MemoryLayout<AudioBuffer>.stride)
                    .assumingMemoryBound(to: AudioBuffer.self)
                secondBufferPtr.pointee = audioBuffers[1]
            }

            status = ExtAudioFileRead(audioFile, &frameCount, bufferListPtr)

            guard status == noErr else {
                throw LibrespotError.decodingFailed("Failed to read audio: \(status)")
            }

            if frameCount == 0 {
                break
            }

            buffer.frameLength = frameCount
            buffers.append(buffer)
            totalRead += Int64(frameCount)
        }

        debugLog("SimpleAudioDecoder", "Decoded \(buffers.count) buffers, \(totalRead) frames")

        return buffers
    }
}
