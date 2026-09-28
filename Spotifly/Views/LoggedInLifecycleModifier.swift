//
//  LoggedInLifecycleModifier.swift
//  Spotifly
//
//  Encapsulates startup and session lifecycle side effects for LoggedInView.
//

import AppKit
import Combine
import SwiftUI

struct LoggedInLifecycleModifier: ViewModifier {
    let store: AppStore
    let playbackViewModel: PlaybackViewModel
    let queueService: QueueService
    let deviceService: DeviceService
    let homeService: HomeService

    @Environment(PlayerModel.self) private var player

    /// Whether readiness has been lost since the last re-sync.
    @State private var connectionDropped = false

    func body(content: Content) -> some View {
        content
            .task {
                // Everything here reads the instances SwiftUI *kept*: this task belongs to
                // the surviving view, while `LoggedInView.init` may have run several times
                // and built a store and services for each run. Those extra objects are
                // inert — they subscribe to nothing and own no state anyone reads — which
                // is only true as long as this stays the single place that wires them up.
                //
                // Before the first `await`, so no Spirc notification can arrive while the
                // player is unobserved.
                queueService.activate()
                playbackViewModel.setStore(store)
                playbackViewModel.setQueueService(queueService)

                #if DEBUG
                    AppStore.current = store
                #endif

                // The profile and the start page are independent requests on the same grant, so
                // they run together. Neither blocks: an app that cannot say who you are is
                // still an app that plays music.
                async let profile: () = loadProfile()
                async let home: () = homeService.loadHome()
                _ = await (profile, home)

                await playbackViewModel.initializeIfNeeded()
                await queueService.fetchInitialPlaybackState()

                #if DEBUG
                    // Headless test scaffolding: SPOTIFLY_DEBUG_AUTOPLAY=1 starts
                    // a fixed album shortly after launch so the Swift playback
                    // stack can be exercised without touching the UI. A
                    // spotify: uri instead of 1 plays that.
                    if let autoplay = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_AUTOPLAY"] {
                        let uri = autoplay.hasPrefix("spotify:") ? autoplay : "spotify:album:1LVj9ljlwsn2DOsXkRDOeI"
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            debugLog("DebugAutoplay", "Starting \(uri)")
                            await playbackViewModel.play(uriOrUrl: uri)

                            // SPOTIFLY_DEBUG_PAUSE_AFTER=<seconds>: pause through the
                            // same PlaybackViewModel path the buttons use, then resume.
                            if let pauseAfter = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_PAUSE_AFTER"],
                               let seconds = Double(pauseAfter)
                            {
                                try? await Task.sleep(for: .seconds(seconds))
                                debugLog("DebugAutoplay", "Pause")
                                playbackViewModel.pause()
                                try? await Task.sleep(for: .seconds(6))
                                debugLog("DebugAutoplay", "Resume")
                                playbackViewModel.resume()
                            }

                            // SPOTIFLY_DEBUG_NEXT_AFTER=<seconds>: skip twice, a
                            // few seconds apart. This is the transition worth
                            // driving headlessly — a track change tears the decode
                            // thread down and closes the decoder out from under it,
                            // and a full track is too long to wait for.
                            if let nextAfter = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_NEXT_AFTER"],
                               let seconds = Double(nextAfter)
                            {
                                for skip in 1 ... 2 {
                                    try? await Task.sleep(for: .seconds(seconds))
                                    debugLog("DebugAutoplay", "Next (\(skip))")
                                    playbackViewModel.next()
                                }
                            }
                        }
                    }

                    // SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER=<seconds>: pull playback
                    // to this device, as picking it in Speakers does. With a second
                    // instance under another SPOTIFLY_DEBUG_DEVICE_ID, a handover
                    // runs both ways on one Mac.
                    if let transferAfter = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER"],
                       let seconds = Double(transferAfter)
                    {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(seconds))
                            debugLog("DebugAutoplay", "Pulling playback here")
                            _ = await SpotifyPlayer.transferToLocal()
                        }
                    }

                    // SPOTIFLY_DEBUG_TRANSFER_TO=<device name> with
                    // SPOTIFLY_DEBUG_TRANSFER_TO_AFTER=<seconds>: hand playback to that
                    // device the way picking it in Speakers does.
                    if let target = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_TRANSFER_TO"],
                       let after = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_TRANSFER_TO_AFTER"],
                       let seconds = Double(after)
                    {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(seconds))
                            guard let device = player.devices.first(where: { $0.name == target }) else {
                                debugLog("DebugAutoplay", "No device named \(target); have \(player.devices.map(\.name))")
                                return
                            }
                            debugLog("DebugAutoplay", "Handing playback to \(target)")
                            let accepted = await deviceService.transferPlayback(to: device)
                            debugLog("DebugAutoplay", "Transfer to \(target) \(accepted ? "accepted" : "rejected")")
                        }
                    }

                    // SPOTIFLY_DEBUG_QUEUE_AFTER=<seconds>: queue a track, then an
                    // album, through the path the context menus use — locally when
                    // this device plays, as Connect commands when another one does.
                    if let queueAfter = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_QUEUE_AFTER"],
                       let seconds = Double(queueAfter)
                    {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(seconds))
                            debugLog("DebugAutoplay", "Queueing a track")
                            await playbackViewModel.addToQueue(uri: "spotify:track:0Y9muyQw5qQ6l7ZMEkkUNG")
                            try? await Task.sleep(for: .seconds(3))
                            debugLog("DebugAutoplay", "Queueing an album")
                            await playbackViewModel.addToQueue(uri: "spotify:album:1LVj9ljlwsn2DOsXkRDOeI")
                        }
                    }
                #endif
            }
            // Connection handling is driven by whether the session is connected, not by
            // which device is active. Activation and connection are different facts:
            // another device taking over says nothing about whether the session is
            // healthy, so a device handoff neither arms the recovery path nor refetches.
            .onChange(of: player.connection?.isConnected == true) { _, isReady in
                guard isReady else {
                    connectionDropped = true
                    return
                }

                // A reconnect is a drop followed by a rise. The rise on its own is also what
                // a cold start looks like, and that one is handled by .task above — so
                // treating every rise as a reconnect doubled the bootstrap on every launch.
                guard connectionDropped else { return }
                connectionDropped = false

                // Re-sync with whatever is playing now.
                Task {
                    await deviceService.waitForTransferSettling()
                    await queueService.fetchInitialPlaybackState()
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                debugLog("LoggedInLifecycle", "System will sleep, disconnecting from Spotify")
                SpotifyPlayer.disconnect()
            }
            // Ask the client to reconnect rather than rebuilding it. A rebuild starts with
            // a destructive cleanup that invalidates whatever reconnect loop is already
            // working the problem, and if the single rebuild attempt then fails there is
            // nothing left retrying.
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                switch SpotifyPlayer.forceReconnect() {
                case .started, .alreadyRecovering:
                    debugLog("LoggedInLifecycle", "System wake detected, reconnect under way")
                case .noSession:
                    // Nothing to reconnect to — after a logout, or if the initial
                    // initialization never succeeded. Only a full rebuild helps here, and
                    // there is no running recovery for it to disturb.
                    debugLog("LoggedInLifecycle", "System wake detected, no session — rebuilding")
                    Task {
                        await playbackViewModel.forceReinitialize()
                    }
                }
            }
    }

    /// Who is logged in. Failure is swallowed, because nothing on this path should block on it:
    /// an app that cannot say who you are is still an app that plays music.
    ///
    /// It is no longer only the settings screen that reads it, though — the playlist library
    /// writes address the rootlist by username — so `PlaylistService.requireProfile` fetches it
    /// itself when it is missing rather than trusting this one attempt.
    private func loadProfile() async {
        do {
            let profile = try await PartnerAPI().profile()
            store.setUserProfile(UserProfile(pathfinder: profile))
        } catch {
            debugLog("LoggedInLifecycle", "Profile unavailable: \(error.localizedDescription)")
        }
    }
}
