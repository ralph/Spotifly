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
    @Environment(AppStore.self) private var store
    @Environment(PlayerModel.self) private var player
    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(QueueService.self) private var queueService
    @Environment(HomeService.self) private var homeService
    @Environment(ProfileService.self) private var profileService
    @Environment(TrackService.self) private var trackService
    /// Only the debug hooks use these two.
    @Environment(DeviceService.self) private var deviceService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

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
                playbackViewModel.attach(store: store, trackService: trackService)

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

                    // SPOTIFLY_DEBUG_REINIT_AFTER=<seconds>: rebuild the session the way
                    // Speakers → Reconnect does, and log what the bar holds before and
                    // after. The model passes on changes only, so a rebuild that loses
                    // the track shows nothing wrong anywhere else.
                    if let reinitAfter = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_REINIT_AFTER"],
                       let seconds = Double(reinitAfter)
                    {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(seconds))
                            debugLog("DebugAutoplay", "Rebuilding; before: \(debugPlaybackSummary())")
                            await playbackViewModel.forceReinitialize()
                            debugLog("DebugAutoplay", "Rebuilt: \(debugPlaybackSummary())")
                            try? await Task.sleep(for: .seconds(3))
                            debugLog("DebugAutoplay", "Rebuilt, 3 s on: \(debugPlaybackSummary())")
                        }
                    }

                    // SPOTIFLY_DEBUG_RESUME_AFTER=<seconds>: press Play, as the bar's
                    // button does. On another device's track, mirrored, that takes it over.
                    if let resumeAfter = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_RESUME_AFTER"],
                       let seconds = Double(resumeAfter)
                    {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(seconds))
                            debugLog("DebugAutoplay", "Resume; before: \(debugPlaybackSummary())")
                            playbackViewModel.resume()
                            try? await Task.sleep(for: .seconds(4))
                            debugLog("DebugAutoplay", "Resumed, 4 s on: \(debugPlaybackSummary())")
                        }
                    }

                    // SPOTIFLY_DEBUG_OPEN=<album, artist or playlist uri>: open that page, for
                    // an id nothing in the app leads to, such as an album from another market.
                    if let open = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_OPEN"] {
                        debugLog("DebugAutoplay", "Opening \(open)")
                        if let route = Route(contextUri: open) {
                            navigationCoordinator.navigate(to: route)
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
            // The two loads started here, asked for again when the network is back. Launched
            // offline, the start page shows its error, and the sidebar has no profile and so no
            // avatar, until the next launch. Here rather than on the start page, which may not
            // be on screen when the network returns. A second profile request, from a return
            // while the launch's is still out, is harmless; skipping it lost the only retry
            // when that one then failed.
            .retryingWhenNetworkReturns(if: store.homeErrorMessage != nil) { await homeService.refresh() }
            .retryingWhenNetworkReturns(if: store.userProfile == nil) { await loadProfile() }
            // And the queue's tracks, which every change of the queue asks for: one that failed
            // offline is not asked for again until the queue changes. A track already loaded
            // costs no request.
            .retryingWhenNetworkReturns { queueService.hydrate() }
            // Playback steps over what the lists said will not play. Initially too, which
            // sends an empty set at login, so nothing of the previous account's is left.
            .onChange(of: store.unplayableTrackUris, initial: true) { _, uris in
                SpotifyPlayer.setUnplayable(uris)
            }
            // And the other way: what playback found withheld, which no list said, is greyed.
            .onChange(of: player.withheld, initial: true) { _, uris in
                store.setWithheld(uris)
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
    /// an app that cannot say who you are is still an app that plays music. A playlist write
    /// asks the same service again when it needs the profile; see `ProfileService.require()`.
    private func loadProfile() async {
        do {
            _ = try await profileService.require()
        } catch {
            debugLog("LoggedInLifecycle", "Profile unavailable: \(error.localizedDescription)")
        }
    }

    #if DEBUG
        /// What the bar shows, and whether the client agrees it is playing.
        private func debugPlaybackSummary() -> String {
            "uri=\(playbackViewModel.currentTrackUri ?? "nil") at \(playbackViewModel.interpolatedPositionMs)ms, "
                + "playing=\(playbackViewModel.isPlaying), client playing=\(SpotifyPlayer.isPlaying), "
                + "active=\(SpotifyPlayer.isActiveDevice)"
        }
    #endif
}
