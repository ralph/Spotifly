//
//  ContainerMigration.swift
//  Spotifly
//
//  Brings the settings out of the old App Sandbox container, once
//

import Foundation

/// Moves what the sandboxed app kept in its container to where the unsandboxed app looks.
///
/// Spotifly ran in the App Sandbox until it started Spotify's Soloist, which a sandboxed app
/// cannot run (`plans/open/soloist-playback.md`). Sandboxed, `UserDefaults` and Application
/// Support resolved into `~/Library/Containers/rvdh.Spotifly/Data`; now they resolve into the
/// user's own `~/Library`. Without this, an upgraded Mac would start with default settings and
/// a new Connect device id (`DeviceInfo`). Caches are left behind: they refill.
///
/// Runs once, first thing at launch, before anything reads a setting. Not in the unit-test
/// host, which writes this domain too (`copySettings` says why that matters). If the container
/// cannot be read, nothing is retried: the settings start from their defaults.
nonisolated enum ContainerMigration {
    static let doneKey = "migratedFromSandboxContainer"

    static func runOnce(
        defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? "rvdh.Spotifly",
        container: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/rvdh.Spotifly/Data"),
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard FileManager.default.fileExists(atPath: container.path) else { return }

        copySettings(
            from: container.appending(path: "Library/Preferences/\(domain).plist"),
            into: defaults,
            domain: domain,
        )
    }

    /// Every setting the container has, over what this domain holds. The container wins because
    /// before this runs, only a Debug run or the unit-test host writes here, and their values,
    /// a fresh Connect device id among them, must not replace the user's. Launch arguments are
    /// a domain of their own, which this does not touch.
    private static func copySettings(from plist: URL, into defaults: UserDefaults, domain: String) {
        do {
            let data = try Data(contentsOf: plist)
            guard let old = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                debugLog("ContainerMigration", "Settings not copied: not a dictionary")
                return
            }
            let current = defaults.persistentDomain(forName: domain) ?? [:]
            defaults.setPersistentDomain(current.merging(old) { _, fromContainer in fromContainer }, forName: domain)
            debugLog("ContainerMigration", "Copied \(old.count) settings")
        } catch {
            debugLog("ContainerMigration", "Settings not copied: \(error)")
        }
    }
}
