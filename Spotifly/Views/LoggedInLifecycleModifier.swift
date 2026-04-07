//
//  LoggedInLifecycleModifier.swift
//  Spotifly
//
//  Encapsulates startup and session lifecycle side effects for LoggedInView.
//

import AppKit
import SwiftUI

struct LoggedInLifecycleModifier: ViewModifier {
    let session: SpotifySession
    let store: AppStore
    let topItemsTimeRange: String
    let reconnectWatchdogTimeoutSeconds: Double
    let playbackViewModel: PlaybackViewModel
    let queueService: QueueService
    let deviceService: DeviceService
    let recentlyPlayedService: RecentlyPlayedService
    let topItemsService: TopItemsService
    @Binding var blockingState: LoggedInView.BlockingState?

    @State private var reconnectWatchdogTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task {
                #if DEBUG
                    AppStore.current = store
                    SpotifySession.current = session
                #endif

                let token = await session.validAccessToken()

                do {
                    let profile = try await SpotifyAPI.getCurrentUserProfile(accessToken: token)
                    store.setUserProfile(profile)
                } catch SpotifyAPIError.forbidden {
                    blockingState = .userNotWhitelisted
                    return
                } catch {
                    // Continue without profile if the request fails for a non-auth reason.
                }

                do {
                    _ = try await SpotifyAPI.fetchAvailableDevices(accessToken: token)
                } catch SpotifyAPIError.forbidden {
                    blockingState = .premiumRequired
                    return
                } catch {
                    // Continue on transient failures and let playback surface any later errors.
                }

                let timeRange = TopItemsTimeRange(rawValue: topItemsTimeRange) ?? .mediumTerm
                async let topArtists: () = topItemsService.loadTopArtists(accessToken: token, timeRange: timeRange)
                async let topTracks: () = topItemsService.loadTopTracks(accessToken: token, timeRange: timeRange)
                async let recentlyPlayed: () = recentlyPlayedService.loadRecentlyPlayed(accessToken: token)

                _ = await (topArtists, topTracks, recentlyPlayed)

                playbackViewModel.setTokenProvider { await session.validAccessToken() }
                SpotifyPlayer.setTokenProvider(session)

                await playbackViewModel.initializeIfNeeded(accessToken: token)
                await queueService.fetchInitialPlaybackState(accessToken: token)
            }
            .onReceive(SpotifyPlayer.sessionConnected) {
                reconnectWatchdogTask?.cancel()
                reconnectWatchdogTask = nil

                Task {
                    let token = await session.validAccessToken()
                    await deviceService.waitForTransferSettling()
                    await queueService.fetchInitialPlaybackState(accessToken: token)
                }
            }
            .onReceive(SpotifyPlayer.sessionDisconnected) {
                reconnectWatchdogTask?.cancel()
                reconnectWatchdogTask = Task {
                    try? await Task.sleep(for: .seconds(reconnectWatchdogTimeoutSeconds))
                    guard !Task.isCancelled, !SpotifyPlayer.isSessionConnected else { return }
                    debugLog(
                        "LoggedInLifecycle",
                        "Watchdog: still disconnected after \(Int(reconnectWatchdogTimeoutSeconds))s, forcing reinit",
                    )
                    let token = await session.validAccessToken()
                    await playbackViewModel.forceReinitialize(accessToken: token)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                debugLog("LoggedInLifecycle", "System will sleep, disconnecting from Spotify")
                SpotifyPlayer.disconnect()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                debugLog("LoggedInLifecycle", "System wake detected, forcing full reinit")
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.forceReinitialize(accessToken: token)
                }
            }
            .onDisappear {
                reconnectWatchdogTask?.cancel()
                reconnectWatchdogTask = nil
            }
    }
}

extension View {
    func loggedInLifecycle(
        session: SpotifySession,
        store: AppStore,
        topItemsTimeRange: String,
        reconnectWatchdogTimeoutSeconds: Double,
        playbackViewModel: PlaybackViewModel,
        queueService: QueueService,
        deviceService: DeviceService,
        recentlyPlayedService: RecentlyPlayedService,
        topItemsService: TopItemsService,
        blockingState: Binding<LoggedInView.BlockingState?>,
    ) -> some View {
        modifier(
            LoggedInLifecycleModifier(
                session: session,
                store: store,
                topItemsTimeRange: topItemsTimeRange,
                reconnectWatchdogTimeoutSeconds: reconnectWatchdogTimeoutSeconds,
                playbackViewModel: playbackViewModel,
                queueService: queueService,
                deviceService: deviceService,
                recentlyPlayedService: recentlyPlayedService,
                topItemsService: topItemsService,
                blockingState: blockingState,
            ),
        )
    }
}
