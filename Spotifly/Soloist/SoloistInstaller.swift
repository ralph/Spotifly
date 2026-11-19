//
//  SoloistInstaller.swift
//  Spotifly
//
//  Downloads Spotify's Soloist, checks that it is Spotify's, and reads when it expires
//

import Foundation
import Security

/// The Soloist build on this Mac. Spotify forbids shipping it inside the app, so it is
/// downloaded from Spotify's CDN, and every build stops starting 90 days after its build date.
nonisolated struct SoloistBuild: Codable, Equatable, Sendable {
    let version: String
    /// The build date `--version` names; the build expires 90 days after it.
    let built: Date

    private static let day: TimeInterval = 86400

    var expires: Date {
        built.addingTimeInterval(90 * Self.day)
    }

    func isUsable(at now: Date) -> Bool {
        now < expires
    }

    /// In its last 30 days, so a renewal that fails leaves time for the next launch.
    func isDue(at now: Date) -> Bool {
        now >= built.addingTimeInterval(60 * Self.day)
    }
}

nonisolated enum SoloistInstaller {
    /// The macOS build. The URL never changes, and Spotify publishes no checksum for it.
    static let archiveURL = URL(string: "https://soloist-builds.spotifycdn.com/soloist_release_osx_arm64.tar.gz")!

    /// Spotify's Developer ID and Soloist's identifier. A build that does not satisfy it is
    /// never run, whatever the download looked like.
    static let requirement =
        #"anchor apple generic and identifier "com.spotify.soloist" and certificate leaf[subject.OU] = "2FNC3A47ZF""#

    enum Failure: LocalizedError {
        case download(Int)
        case unpack
        case notSpotifys
        case unreadableVersion
        case expired

        var errorDescription: String? {
            switch self {
            case let .download(status):
                String(localized: "soloist.error.download \(status)")
            case .unpack:
                String(localized: "soloist.error.unpack")
            case .notSpotifys:
                String(localized: "soloist.error.signature")
            case .unreadableVersion, .expired:
                String(localized: "soloist.error.expired")
            }
        }
    }

    /// The executable of `build` under `root`.
    static func executable(of build: SoloistBuild, in root: URL) -> URL {
        root.appending(path: "builds/\(build.version)/soloist")
    }

    /// The build installed last, if it is recorded.
    static func current(in root: URL) -> SoloistBuild? {
        guard let data = try? Data(contentsOf: root.appending(path: "build.json")) else { return nil }
        return try? JSONDecoder().decode(SoloistBuild.self, from: data)
    }

    /// Downloads the current build into `root/builds/<version>`, checks it, and records it.
    static func install(into root: URL) async throws -> SoloistBuild {
        debugLog("Soloist", "[GET] \(archiveURL.absoluteString)")
        let (download, response) = try await URLSession.shared.download(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: download) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, response.url?.host() == archiveURL.host() else {
            throw Failure.download(status)
        }

        let builds = root.appending(path: "builds")
        let stage = builds.appending(path: "staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        // bsdtar refuses absolute paths, `..` and writing through links unless told otherwise,
        // and the signature check below decides whether what came out is run at all.
        guard try await run(URL(filePath: "/usr/bin/tar"), ["-xzf", download.path, "-C", stage.path]).status == 0 else {
            throw Failure.unpack
        }
        let executable = stage.appending(path: "soloist")
        let type = try? FileManager.default.attributesOfItem(atPath: executable.path)[.type] as? FileAttributeType
        guard type == .typeRegular, await isSpotifys(executable) else {
            throw Failure.notSpotifys
        }

        let printed = try await run(executable, ["--version"])
        guard printed.status == 0, let build = parse(version: printed.output) else {
            throw Failure.unreadableVersion
        }
        guard build.isUsable(at: Date()) else {
            throw Failure.expired
        }

        let destination = builds.appending(path: build.version)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: stage, to: destination)
        }
        try JSONEncoder().encode(build).write(to: root.appending(path: "build.json"), options: .atomic)
        debugLog("Soloist", "Installed \(build.version), expires \(build.expires)")
        return build
    }

    /// Reads `soloist 1.3.10.37 build 1793685705 (20261103) …`: the version, and the build
    /// date as seconds since 1970.
    static func parse(version text: String) -> SoloistBuild? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.first == "soloist", words.count > 1,
              let index = words.firstIndex(of: "build"), words.indices.contains(index + 1),
              let seconds = TimeInterval(words[index + 1])
        else { return nil }
        return SoloistBuild(version: String(words[1]), built: Date(timeIntervalSince1970: seconds))
    }

    /// Whether `executable` is signed by Spotify as Soloist, and intact. Off the main thread:
    /// hashing the 26 MB binary takes 50–80 ms, and it runs at every launch.
    @concurrent
    static func isSpotifys(_ executable: URL) async -> Bool {
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess, let required
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, required) == errSecSuccess
    }

    /// Runs a program to its end and returns its exit status and standard output.
    static func run(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let output = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
