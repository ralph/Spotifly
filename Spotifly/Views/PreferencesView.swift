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
                    .settingsPage(height: 280)
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

/// What plays on this Mac: Spotify's Soloist, the only player, whose one setting here is its key.
private struct PlaybackSettingsView: View {
    var body: some View {
        Form {
            SoloistSection()
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Spotify's Soloist as this Mac's player: the key, the download, and where it stands
/// (`SoloistEngine`). Once set up, the key can be changed, which restarts Soloist with it.
private struct SoloistSection: View {
    @AppStorage(SoloistEngine.setUpKey) private var isSetUp = false
    @State private var key = ""
    private let engine = SoloistEngine.shared

    var body: some View {
        Section {
            if isSetUp {
                LabeledContent("soloist.status") {
                    Text(statusText)
                        .foregroundStyle(isFailed ? .red : .secondary)
                }
            }
            SecureField("soloist.key", text: $key)
            HStack {
                Link("soloist.get_key", destination: URL(string: "https://developer.spotify.com/dashboard/soloist")!)
                Spacer()
                Button(isSetUp ? "soloist.change_key" : "soloist.use") {
                    let entered = key
                    key = ""
                    Task { await engine.choose(key: entered) }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(verbatim: "Spotify Soloist")
        } footer: {
            Text("soloist.footer")
        }
    }

    private var isFailed: Bool {
        if case .failed = engine.status {
            true
        } else {
            false
        }
    }

    private var statusText: String {
        switch engine.status {
        case .off: String(localized: "soloist.status.off")
        case .installing: String(localized: "soloist.status.installing")
        case .starting: String(localized: "soloist.status.starting")
        case .waitingForPairing: String(localized: "soloist.status.pairing")
        case .ready where PlayerModel.shared.isPlayingHere: String(localized: "soloist.status.playing")
        case .ready: String(localized: "soloist.status.ready")
        case let .failed(message): message
        }
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
