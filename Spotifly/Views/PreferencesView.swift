//
//  PreferencesView.swift
//  Spotifly
//
//  The settings window: General, Playback and Shortcuts, with the version at its foot
//

import SwiftUI

/// The redesign's settings window (`plans/done/redesign-settings.md`): only what the app acts on.
/// The handoff's offline cache, Dock and notification switches, volume levelling and Autoplay
/// have nothing behind them here, so they are not offered.
struct PreferencesView: View {
    var body: some View {
        // Each tab its own height, so the window fits the tab shown, as a settings window does.
        TabView {
            Tab("preferences.general", systemImage: "gearshape") {
                GeneralSettingsView()
                    .settingsPage(height: 90)
            }

            Tab("preferences.playback", systemImage: "speaker.wave.3") {
                PlaybackSettingsView()
                    .settingsPage(height: 170)
            }

            Tab("preferences.shortcuts", systemImage: "command") {
                ShortcutsSettingsView()
                    .settingsPage(height: 420)
            }
        }
    }
}

private extension View {
    /// A tab of the window: 600 pt wide, the height given, and the version at its foot.
    func settingsPage(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            frame(height: height)
            VersionFooter()
        }
        .frame(width: 600)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceMode: AppearanceMode = .system

    var body: some View {
        Form {
            Picker("preferences.appearance", selection: Binding(
                get: { appearanceMode },
                set: { newValue in
                    appearanceMode = newValue
                    newValue.apply()
                },
            )) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.titleKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Playback

private struct PlaybackSettingsView: View {
    @AppStorage("streamingBitrate") private var bitrateRawValue: Int = 1
    @AppStorage("gaplessPlayback") private var gaplessEnabled: Bool = true

    private var selectedBitrate: SpotifyPlayer.Bitrate {
        SpotifyPlayer.Bitrate(rawValue: UInt8(bitrateRawValue)) ?? .normal
    }

    var body: some View {
        Form {
            Section {
                Picker("preferences.streaming_quality", selection: Binding(
                    get: { selectedBitrate },
                    // The player stores it, and the storage tells this view.
                    set: { SpotifyPlayer.setBitrate($0) },
                )) {
                    ForEach(SpotifyPlayer.Bitrate.allCases) { bitrate in
                        Text(verbatim: "\(bitrate.kilobitsPerSecond) kbit/s")
                            .tag(bitrate)
                    }
                }

                Toggle("preferences.gapless_playback", isOn: Binding(
                    get: { gaplessEnabled },
                    set: { SpotifyPlayer.setGapless($0) },
                ))
            } footer: {
                Text("preferences.restart_note")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Shortcuts

/// The app's shortcuts, read-only, from the table the menus bind (`AppShortcut`).
private struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            ForEach(AppShortcut.allCases, id: \.self) { shortcut in
                LabeledContent(shortcut.title) {
                    Text(verbatim: shortcut.glyphs)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Footer

/// The version and where the source lives, under every tab.
private struct VersionFooter: View {
    private var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(DeviceInfo.appVersion) (\(build))"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(String(localized: "app.name")) \(version)")
            Text("metadata.separator")
            Link(destination: URL(string: "https://github.com/ralph/Spotifly")!) {
                Text(verbatim: "github.com/ralph/Spotifly")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
    }
}
