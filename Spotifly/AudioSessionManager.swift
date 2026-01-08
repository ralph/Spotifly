//
//  AudioSessionManager.swift
//  Spotifly
//
//  Manages audio session configuration for iOS/iPadOS
//  Handles background playback and interruptions
//

import Combine
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    @Published var isSessionActive = false

    private init() {}

    /// Sets up the audio session for playback
    /// Required for iOS/iPadOS background audio and proper audio routing
    func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        do {
            // .playback ensures audio continues in silent mode and background
            try session.setCategory(.playback, mode: .default, options: [])

            // Activate the session
            try session.setActive(true)

            isSessionActive = true
            print("Audio session configured for playback")

            setupInterruptionHandling()
        } catch {
            print("Failed to configure audio session: \(error)")
            isSessionActive = false
        }
        #else
        // macOS doesn't require audio session configuration
        isSessionActive = true
        #endif
    }

    /// Deactivates the audio session
    func deactivateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            isSessionActive = false
            print("Audio session deactivated")
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        #endif
    }

    #if os(iOS)
    /// Sets up handling for audio interruptions (phone calls, alarms, etc.)
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else {
                return
            }

            switch type {
            case .began:
                // Audio was interrupted (e.g., incoming phone call)
                print("Audio interruption began - playback will pause")
                // The system automatically pauses audio playback
                // Post notification so PlaybackViewModel can update its state
                NotificationCenter.default.post(
                    name: .audioInterruptionBegan,
                    object: nil
                )

            case .ended:
                // Interruption ended
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        print("Audio interruption ended - can resume playback")
                        // Post notification so PlaybackViewModel can resume if needed
                        NotificationCenter.default.post(
                            name: .audioInterruptionEnded,
                            object: nil,
                            userInfo: ["shouldResume": true]
                        )
                    } else {
                        print("Audio interruption ended - should not auto-resume")
                        NotificationCenter.default.post(
                            name: .audioInterruptionEnded,
                            object: nil,
                            userInfo: ["shouldResume": false]
                        )
                    }
                }

            @unknown default:
                break
            }
        }

        // Handle route changes (headphones plugged/unplugged, etc.)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            else {
                return
            }

            switch reason {
            case .oldDeviceUnavailable:
                // Headphones were unplugged - pause playback
                print("Audio route changed - old device unavailable (e.g., headphones unplugged)")
                NotificationCenter.default.post(
                    name: .audioRouteChanged,
                    object: nil,
                    userInfo: ["shouldPause": true]
                )

            default:
                print("Audio route changed: \(reason.rawValue)")
                break
            }
        }
    }
    #endif
}

// MARK: - Notification Names

extension Notification.Name {
    static let audioInterruptionBegan = Notification.Name("audioInterruptionBegan")
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
    static let audioRouteChanged = Notification.Name("audioRouteChanged")
}
