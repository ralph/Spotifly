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

            SpeakersSettingsView()
                .tabItem {
                    Label("preferences.speakers", systemImage: "hifispeaker.2")
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

// MARK: - Startpage Settings Tab

/// Identifiers for startpage sections
enum StartpageSection: String, CaseIterable, Identifiable, Codable {
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

    var enabledKey: String {
        switch self {
        case .topArtists: "showTopArtists"
        case .recentlyPlayed: "showRecentlyPlayed"
        case .newReleases: "showNewReleases"
        }
    }

    /// Default order of sections
    static var defaultOrder: [StartpageSection] {
        [.topArtists, .recentlyPlayed, .newReleases]
    }
}

struct StartpageSettingsView: View {
    @AppStorage("showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("showRecentlyPlayed") private var showRecentlyPlayed: Bool = true
    @AppStorage("showNewReleases") private var showNewReleases: Bool = true
    @AppStorage("startpageSectionOrder") private var sectionOrderData: Data = .init()

    @State private var sections: [StartpageSection] = StartpageSection.defaultOrder
    @State private var draggingSection: StartpageSection?

    /// Whether any section is enabled
    private var hasAnySectionEnabled: Bool {
        showTopArtists || showRecentlyPlayed || showNewReleases
    }

    var body: some View {
        Form {
            Section {
                ForEach(sections) { section in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .font(.body)

                        Toggle(section.titleKey, isOn: bindingForSection(section))

                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .opacity(draggingSection == section ? 0.5 : 1.0)
                    .onDrag {
                        draggingSection = section
                        return NSItemProvider(object: section.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: SectionDropDelegate(
                        item: section,
                        sections: $sections,
                        draggingSection: $draggingSection,
                        onReorder: saveSectionOrder,
                    ))
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
        .onAppear {
            loadSectionOrder()
        }
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

    private func loadSectionOrder() {
        guard !sectionOrderData.isEmpty,
              let order = try? JSONDecoder().decode([StartpageSection].self, from: sectionOrderData)
        else {
            sections = StartpageSection.defaultOrder
            return
        }
        // Ensure all sections are present (in case new ones were added)
        var loadedSections = order.filter { StartpageSection.allCases.contains($0) }
        for section in StartpageSection.allCases where !loadedSections.contains(section) {
            loadedSections.append(section)
        }
        sections = loadedSections
    }

    private func saveSectionOrder() {
        if let data = try? JSONEncoder().encode(sections) {
            sectionOrderData = data
        }
    }
}

/// Drop delegate for reordering startpage sections
struct SectionDropDelegate: DropDelegate {
    let item: StartpageSection
    @Binding var sections: [StartpageSection]
    @Binding var draggingSection: StartpageSection?
    let onReorder: () -> Void

    func performDrop(info _: DropInfo) -> Bool {
        draggingSection = nil
        onReorder()
        return true
    }

    func dropEntered(info _: DropInfo) {
        guard let dragging = draggingSection,
              dragging != item,
              let fromIndex = sections.firstIndex(of: dragging),
              let toIndex = sections.firstIndex(of: item)
        else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            sections.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
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
