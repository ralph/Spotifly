//
//  SoloistEngine.swift
//  Spotifly
//
//  Runs Spotify's Soloist as this Mac's player, and says whether it is ready
//

import AppKit
import Darwin
import Foundation
import Synchronization

/// Spotify's Soloist, run as a child process, is this Mac's player once the user has chosen it.
///
/// Soloist is a Spotify Connect receiver that plays with Spotify's own engine and needs no audio
/// keys. Spotifly starts it, and controls it like any other Connect device: plays and commands
/// go over connect-state, and what it plays comes back in the cluster. Its loopback WebSocket
/// only says what the cluster cannot: whether it runs, whether it is paired, whether it is
/// active. Spotifly's own Connect device then registers hidden (`LibrespotClient`), so the
/// account sees one device for this Mac, named `deviceName`.
///
/// `plans/open/soloist-playback.md` has the research behind it.
@MainActor
@Observable
final class SoloistEngine {
    static let shared = SoloistEngine()

    enum Status: Equatable {
        case off
        case installing
        case starting
        /// Running, and waiting to be picked once in an official Spotify app.
        case waitingForPairing
        case ready
        case failed(String)
    }

    private(set) var status: Status = .off

    /// Whether Soloist is the active Connect device, as its socket says.
    private(set) var isActive = false

    /// Soloist's Connect device id, which the cluster lists it by.
    private(set) var deviceId: String?

    /// The name the account's device lists show for this Mac.
    static let deviceName = "Spotifly"

    private nonisolated static let chosenKey = "soloistEngine"

    /// Whether the user chose Soloist as this Mac's player. Read off the main actor by the
    /// client when it registers this Mac's own device.
    nonisolated static var isChosen: Bool {
        UserDefaults.standard.bool(forKey: chosenKey)
    }

    /// The device to play on: Soloist, while it is chosen and ready.
    var readyDeviceId: String? {
        status == .ready ? deviceId : nil
    }

    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var isStarting = false
    private var isStopping = false
    private var restartsInARow = 0

    /// The child's pid, for `atexit`, which cannot reach the main actor.
    private nonisolated static let childPID = Atomic<Int32>(0)

    private init() {
        // A crash or a force quit skips `stop()`. The child must not outlive the app.
        atexit {
            let pid = SoloistEngine.childPID.load(ordering: .relaxed)
            if pid > 0 {
                kill(pid, SIGKILL)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { SoloistEngine.shared.stop() }
        }
    }

    // MARK: - Files

    /// Private to this user: Soloist writes its stored login readable by everyone (probe 4 of
    /// the plan), so the folder above it is what keeps others out.
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Spotifly/Soloist")
    }

    private static var data: URL {
        root.appending(path: "data")
    }

    private static func makePrivateDirectories() throws {
        for directory in [root, data, root.appending(path: "cache")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    // MARK: - Choosing it

    /// Stores the key, makes Soloist this Mac's player, and starts it. This Mac's own device
    /// registers again, hidden, so the account does not list two players for it.
    func choose(key: String) async {
        do {
            try KeychainManager.saveSoloistKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        UserDefaults.standard.set(true, forKey: Self.chosenKey)
        restartsInARow = 0
        await start()
        await PlaybackViewModel.shared.forceReinitialize()
    }

    /// Back to the built-in player.
    func turnOff() async {
        UserDefaults.standard.set(false, forKey: Self.chosenKey)
        stop()
        status = .off
        await PlaybackViewModel.shared.forceReinitialize()
    }

    /// Starts Soloist if it is chosen and not running: installs or renews the build first.
    func start() async {
        guard Self.isChosen, process == nil, !isStarting else { return }
        guard let key = KeychainManager.loadSoloistKey(), !key.isEmpty else {
            status = .failed(String(localized: "soloist.error.no_key"))
            return
        }
        isStarting = true
        isStopping = false
        defer { isStarting = false }

        do {
            try Self.makePrivateDirectories()
            let build = try await currentBuild()
            let executable = SoloistInstaller.executable(of: build, in: Self.root)
            guard SoloistInstaller.isSpotifys(executable) else {
                throw SoloistInstaller.Failure.notSpotifys
            }
            status = .starting
            stopLeftoverChild()
            try launch(executable, key: key)
            deviceId = try? String(contentsOf: Self.data.appending(path: ".device_id"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await connectSocket()
        } catch {
            debugLog("Soloist", "Start failed: \(error)")
            stop()
            status = .failed(error.localizedDescription)
        }
    }

    /// The build to run: the recorded one while it is usable, renewed in its last 30 days.
    private func currentBuild() async throws -> SoloistBuild {
        let now = Date()
        if let build = SoloistInstaller.current(in: Self.root), build.isUsable(at: now),
           FileManager.default.fileExists(atPath: SoloistInstaller.executable(of: build, in: Self.root).path)
        {
            guard build.isDue(at: now) else { return build }
            // A failed renewal leaves the old build running until the next launch tries again.
            status = .installing
            return await (try? SoloistInstaller.install(into: Self.root)) ?? build
        }
        status = .installing
        return try await SoloistInstaller.install(into: Self.root)
    }

    // MARK: - The process

    private func launch(_ executable: URL, key: String) throws {
        try? FileManager.default.removeItem(at: Self.data.appending(path: "ws.port"))

        let volume = UserDefaults.standard.object(forKey: "playbackVolume") as? Double ?? 0.5
        let process = Process()
        process.executableURL = executable
        // The key can only be passed as an argument (soloist#12): `ps` shows it to local users.
        process.arguments = [
            "-n", Self.deviceName,
            "-k", key,
            "-D", Self.data.path,
            "-C", Self.root.appending(path: "cache").path,
            "-z", "512",
            "-i", String(Int((volume * 100).rounded())),
            "-w", "127.0.0.1:0",
        ]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // Its log names the account and the track; the key is taken out in case it names that too.
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                debugLog("Soloist", line.replacingOccurrences(of: key, with: "<key>"))
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in SoloistEngine.shared.processEnded(status: status) }
        }

        try process.run()
        self.process = process
        Self.childPID.store(process.processIdentifier, ordering: .relaxed)
        debugLog("Soloist", "Started pid \(process.processIdentifier)")
    }

    /// Restarts a child that ended on its own. Exit code 10 means the build expired, which a
    /// fresh download fixes.
    private func processEnded(status exitStatus: Int32) {
        debugLog("Soloist", "Exited with status \(exitStatus)")
        Self.childPID.store(0, ordering: .relaxed)
        process = nil
        socket?.cancel()
        socket = nil
        isActive = false
        guard !isStopping, Self.isChosen else { return }

        if exitStatus == 10 {
            try? FileManager.default.removeItem(at: Self.root.appending(path: "build.json"))
        }
        restartsInARow += 1
        guard restartsInARow <= 5 else {
            status = .failed(String(localized: "soloist.error.keeps_stopping"))
            return
        }
        status = .starting
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await start()
        }
    }

    /// Stops the child. Called on quit, and when the user turns Soloist off.
    func stop() {
        isStopping = true
        socket?.cancel()
        socket = nil
        if let process, process.isRunning {
            process.terminate()
            // A moment to leave Spotify Connect cleanly; `atexit` kills what is left.
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                usleep(20000)
            }
        }
        if process?.isRunning != true {
            Self.childPID.store(0, ordering: .relaxed)
        }
        process = nil
        isActive = false
    }

    /// A child left over from a run of the app that did not stop it: Soloist refuses to share
    /// its data directory, so it would block this start.
    private func stopLeftoverChild() {
        guard let text = try? String(contentsOf: Self.data.appending(path: "soloist.pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0, String(decoding: path.prefix(Int(length)), as: UTF8.self).hasPrefix(Self.root.path)
        else { return }
        debugLog("Soloist", "Stopping leftover pid \(pid)")
        kill(pid, SIGTERM)
        usleep(500_000)
    }

    // MARK: - The socket

    private func connectSocket() async throws {
        let portFile = Self.data.appending(path: "ws.port")
        var port: Int?
        for _ in 0 ..< 100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8),
               let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                port = value
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let port, let url = URL(string: "ws://127.0.0.1:\(port)") else {
            throw SoloistInstaller.Failure.unpack
        }
        if deviceId == nil {
            deviceId = try? String(contentsOf: Self.data.appending(path: ".device_id"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        self.socket = socket
        Task { await listen(to: socket) }
    }

    private func listen(to socket: URLSessionWebSocketTask) async {
        while let message = try? await socket.receive() {
            guard case let .string(text) = message, let event = SoloistEvent(json: text) else { continue }
            apply(event)
        }
        debugLog("Soloist", "Socket closed")
    }

    func apply(_ event: SoloistEvent) {
        if let loggedIn = event.loggedIn {
            status = loggedIn ? .ready : .waitingForPairing
            if loggedIn {
                restartsInARow = 0
            }
        }
        if let active = event.isActive {
            isActive = active
        }
    }
}

/// The part of a Soloist socket message the engine reads: `auth_state` says whether it is
/// paired, and it and `device_changed` and `playback_state` say whether it is active.
nonisolated struct SoloistEvent: Decodable, Equatable {
    let type: String
    let loggedIn: Bool?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case loggedIn = "logged_in"
        case isActive = "is_active"
    }

    init?(json: String) {
        guard let event = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = event
    }

    init(type: String, loggedIn: Bool?, isActive: Bool?) {
        self.type = type
        self.loggedIn = loggedIn
        self.isActive = isActive
    }
}
