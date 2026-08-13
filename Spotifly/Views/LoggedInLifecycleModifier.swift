//
//  LoggedInLifecycleModifier.swift
//  Spotifly
//
//  Encapsulates startup and session lifecycle side effects for LoggedInView.
//

import AppKit
import SwiftUI

struct LoggedInLifecycleModifier: ViewModifier {
    let store: AppStore
    let playbackViewModel: PlaybackViewModel
    let queueService: QueueService
    let deviceService: DeviceService
    let connectionService: ConnectionService
    let homeService: HomeService

    /// Last observed connection readiness; nil until the first snapshot arrives.
    @State private var wasConnectionReady: Bool?

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
                deviceService.activate()
                connectionService.activate()
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
            }
            // Connection handling is driven by the connection snapshot, not by the Connect
            // activation callbacks. Activation and connection are different facts: another
            // device taking over emits a deactivation, and re-activating emits an
            // activation, neither of which says anything about whether the session is
            // healthy. Keying off readiness means a device handoff no longer arms the
            // recovery path or triggers a Web API refetch.
            .onReceive(SpotifyPlayer.connectionState) { state in
                let isReady = state?.sessionConnected == true && state?.spircReady == true
                defer { wasConnectionReady = isReady }

                // Only react to transitions.
                guard let wasReady = wasConnectionReady, wasReady != isReady else { return }

                guard isReady else {
                    connectionDropped = true
                    return
                }

                // A reconnect is a drop followed by a rise. The rise on its own is also what
                // a cold start looks like, and that one is handled by .task above — so
                // treating every rise as a reconnect doubled the bootstrap on every launch.
                // Waiting for `wasConnectionReady` to be non-nil did not prevent that:
                // `connectionState` is a CurrentValueSubject, so subscribing delivers its
                // seed immediately and the first real transition is never the first callback.
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
            // Ask Rust to reconnect rather than rebuilding from Swift. A rebuild starts with
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

extension View {
    func loggedInLifecycle(
        store: AppStore,
        playbackViewModel: PlaybackViewModel,
        queueService: QueueService,
        deviceService: DeviceService,
        connectionService: ConnectionService,
        homeService: HomeService,
    ) -> some View {
        modifier(
            LoggedInLifecycleModifier(
                store: store,
                playbackViewModel: playbackViewModel,
                queueService: queueService,
                deviceService: deviceService,
                connectionService: connectionService,
                homeService: homeService,
            ),
        )
    }
}
