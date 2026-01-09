//
//  PreferencesView.swift
//  Spotifly
//
//  Preferences window with tabbed interface
//

import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            PlaybackSettingsView()
                .tabItem {
                    Label("preferences.playback", systemImage: "speaker.wave.3")
                }

            SpeakersSettingsView()
                .tabItem {
                    Label("preferences.speakers", systemImage: "hifispeaker.2")
                }

            InfoView()
                .tabItem {
                    Label("preferences.info", systemImage: "info.circle")
                }
        }
        .frame(width: 450)
    }
}

// MARK: - Playback Settings Tab

struct PlaybackSettingsView: View {
    @AppStorage("streamingBitrate") private var bitrateRawValue: Int = 1
    @AppStorage("gaplessPlayback") private var gaplessEnabled: Bool = true

    private var selectedBitrate: SpotifyPlayer.Bitrate {
        get { SpotifyPlayer.Bitrate(rawValue: UInt8(bitrateRawValue)) ?? .normal }
        set { bitrateRawValue = Int(newValue.rawValue) }
    }

    var body: some View {
        Form {
            Picker("preferences.streaming_quality", selection: Binding(
                get: { selectedBitrate },
                set: { newValue in
                    bitrateRawValue = Int(newValue.rawValue)
                    SpotifyPlayer.setBitrate(newValue)
                },
            )) {
                ForEach(SpotifyPlayer.Bitrate.allCases) { bitrate in
                    Text(bitrate.isDefault ? "\(bitrate.displayName) (\(String(localized: "preferences.default")))" : bitrate.displayName)
                        .tag(bitrate)
                }
            }

            Toggle("preferences.gapless_playback", isOn: Binding(
                get: { gaplessEnabled },
                set: { newValue in
                    gaplessEnabled = newValue
                    SpotifyPlayer.setGapless(newValue)
                },
            ))

            Text("preferences.restart_note")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync UI with actual player settings
            SpotifyPlayer.setBitrate(selectedBitrate)
            SpotifyPlayer.setGapless(gaplessEnabled)
        }
    }
}

// MARK: - Speakers Settings Tab

struct SpeakersSettingsView: View {
    @AppStorage("showSpotifyConnectSpeakers") private var showConnectSpeakers: Bool = false
    @AppStorage("showAirPlaySpeakers") private var showAirPlaySpeakers: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("preferences.speakers.connect", isOn: $showConnectSpeakers)
                Text("preferences.speakers.connect_description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("preferences.speakers.airplay", isOn: $showAirPlaySpeakers)
                Text("preferences.speakers.airplay_description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !showConnectSpeakers, !showAirPlaySpeakers {
                Section {
                    Text("preferences.speakers.none_enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Info Tab

struct InfoView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var copyrightYear: String {
        let year = Calendar.current.component(.year, from: Date())
        return String(year)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Spotifly")
                .font(.title2)
                .fontWeight(.semibold)

            Text("preferences.version \(appVersion) (\(buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("preferences.copyright \(copyrightYear)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://github.com/ralph/homebrew-spotifly")!) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("github.com/ralph/homebrew-spotifly")
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}
