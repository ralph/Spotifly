//
//  PreferencesView.swift
//  Spotifly
//
//  Preferences window with tabbed interface
//

import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    var body: some View {
        TabView {
            PlaybackSettingsView()
                .tabItem {
                    Label("preferences.playback", systemImage: "speaker.wave.3")
                }

            StartpageSettingsView()
                .tabItem {
                    Label("nav.startpage", systemImage: "house")
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

// MARK: - Startpage Settings Tab

/// Identifiers for startpage sections
enum StartpageSection: String, CaseIterable, Identifiable {
    case topArtists
    case recentlyPlayed
    case newReleases

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .topArtists: "startpage.top_artists"
        case .recentlyPlayed: "recently_played.content"
        case .newReleases: "startpage.new_releases"
        }
    }
}

struct StartpageSettingsView: View {
    @AppStorage("showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("showRecentlyPlayed") private var showRecentlyPlayed: Bool = true
    @AppStorage("showNewReleases") private var showNewReleases: Bool = true

    /// Whether any section is enabled
    private var hasAnySectionEnabled: Bool {
        showTopArtists || showRecentlyPlayed || showNewReleases
    }

    var body: some View {
        Form {
            Section {
                ForEach(StartpageSection.allCases) { section in
                    Toggle(section.titleKey, isOn: bindingForSection(section))
                }
            } header: {
                Text("preferences.startpage.sections")
            }

            if !hasAnySectionEnabled {
                Section {
                    Text("preferences.startpage.none_enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bindingForSection(_ section: StartpageSection) -> Binding<Bool> {
        switch section {
        case .topArtists:
            $showTopArtists
        case .recentlyPlayed:
            $showRecentlyPlayed
        case .newReleases:
            $showNewReleases
        }
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
