//
//  ChunkedDownloader.swift
//  SwiftLibrespot
//
//  CDN streaming with chunked downloads
//

import Foundation

/// Configuration for chunk downloading
public enum DownloadConfig: Sendable {
    /// Size of each chunk in bytes
    public nonisolated static let chunkSize = 512 * 1024 // 512 KB

    /// Number of chunks to prefetch ahead
    public nonisolated static let prefetchCount = 3

    /// Number of bytes to preload before playback can start
    public nonisolated static let preloadBeforePlay = 44100 * 2 * 2 // 1 second of 44.1kHz stereo 16-bit
}

/// Downloads audio files in chunks from CDN
public actor ChunkedDownloader {
    // MARK: - Properties

    private var session: URLSession
    private var currentDownload: DownloadState?

    /// Download state for a track
    struct DownloadState: Sendable {
        let url: URL
        let fileId: Data
        var totalSize: Int
        var downloadedChunks: Set<Int>
        var chunkData: [Int: Data]
        var isComplete: Bool
    }

    // MARK: - Initialization

    public init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024, // 50 MB memory
            diskCapacity: 200 * 1024 * 1024, // 200 MB disk
            diskPath: "SpotifyAudioCache",
        )
        session = URLSession(configuration: config)
    }

    // MARK: - Downloading

    /// Start downloading a track
    public func startDownload(cdnUrl: URL, fileId: Data) async throws {
        debugLog("ChunkedDownloader", "Starting download: \(cdnUrl)")

        // Get file size with HEAD request
        var headRequest = URLRequest(url: cdnUrl)
        headRequest.httpMethod = "HEAD"

        let (_, response) = try await session.data(for: headRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
              let totalSize = Int(contentLength)
        else {
            throw LibrespotError.cdnError("Failed to get file size")
        }

        debugLog("ChunkedDownloader", "File size: \(totalSize) bytes")

        currentDownload = DownloadState(
            url: cdnUrl,
            fileId: fileId,
            totalSize: totalSize,
            downloadedChunks: [],
            chunkData: [:],
            isComplete: false,
        )

        // Start prefetching initial chunks
        for i in 0 ..< DownloadConfig.prefetchCount {
            Task {
                try? await downloadChunk(index: i)
            }
        }
    }

    /// Download a specific chunk
    public func downloadChunk(index: Int) async throws -> Data {
        guard var download = currentDownload else {
            throw LibrespotError.invalidState("No active download")
        }

        // Check if already downloaded
        if let data = download.chunkData[index] {
            return data
        }

        let startByte = index * DownloadConfig.chunkSize
        let endByte = min(startByte + DownloadConfig.chunkSize - 1, download.totalSize - 1)

        debugLog("ChunkedDownloader", "Downloading chunk \(index): bytes \(startByte)-\(endByte)")

        var request = URLRequest(url: download.url)
        request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 206 || httpResponse.statusCode == 200
        else {
            throw LibrespotError.cdnError("Chunk download failed")
        }

        // Store chunk
        download.downloadedChunks.insert(index)
        download.chunkData[index] = data
        currentDownload = download

        debugLog("ChunkedDownloader", "Chunk \(index) downloaded: \(data.count) bytes")

        // Prefetch next chunks
        for i in 1 ... DownloadConfig.prefetchCount {
            let nextIndex = index + i
            let nextStartByte = nextIndex * DownloadConfig.chunkSize
            if nextStartByte < download.totalSize, !download.downloadedChunks.contains(nextIndex) {
                Task {
                    try? await downloadChunk(index: nextIndex)
                }
            }
        }

        return data
    }

    /// Get data for a byte range (may span multiple chunks)
    public func getData(from startByte: Int, length: Int) async throws -> Data {
        guard currentDownload != nil else {
            throw LibrespotError.invalidState("No active download")
        }

        let startChunk = startByte / DownloadConfig.chunkSize
        let endChunk = (startByte + length - 1) / DownloadConfig.chunkSize

        var result = Data(capacity: length)

        for chunkIndex in startChunk ... endChunk {
            let chunkData = try await downloadChunk(index: chunkIndex)

            let chunkStartByte = chunkIndex * DownloadConfig.chunkSize
            let offsetInChunk = max(0, startByte - chunkStartByte)
            let chunkEndByte = chunkStartByte + chunkData.count
            let bytesToTake = min(
                chunkData.count - offsetInChunk,
                startByte + length - max(startByte, chunkStartByte),
            )

            if bytesToTake > 0, offsetInChunk < chunkData.count {
                result.append(chunkData.subdata(in: offsetInChunk ..< (offsetInChunk + bytesToTake)))
            }
        }

        return result
    }

    /// Cancel current download
    public func cancelDownload() {
        debugLog("ChunkedDownloader", "Download cancelled")
        currentDownload = nil
    }

    /// Check if initial data is available for playback
    public func isReadyForPlayback() -> Bool {
        guard let download = currentDownload else { return false }

        // Check if we have enough data to start
        let bytesNeeded = DownloadConfig.preloadBeforePlay
        let chunksNeeded = (bytesNeeded + DownloadConfig.chunkSize - 1) / DownloadConfig.chunkSize

        for i in 0 ..< chunksNeeded {
            if !download.downloadedChunks.contains(i) {
                return false
            }
        }

        return true
    }

    /// Get total download progress (0.0 - 1.0)
    public func downloadProgress() -> Double {
        guard let download = currentDownload else { return 0 }

        let totalChunks = (download.totalSize + DownloadConfig.chunkSize - 1) / DownloadConfig.chunkSize
        return Double(download.downloadedChunks.count) / Double(totalChunks)
    }
}
