//
//  ActivationRegistry.swift
//  Spotifly
//
//  Debug guard against a discarded service coming alive.
//

import Foundation

#if DEBUG
    /// The instance of each service type that has been activated so far.
    @MainActor private var activatedServices: [String: ObjectIdentifier] = [:]

    /// Warns when a *second* instance of a service goes live.
    ///
    /// SwiftUI runs a View's `init` repeatedly and keeps only the first
    /// `State(initialValue:)`, so a service built there exists in several copies. That is
    /// harmless only while construction stays inert and exactly one copy is ever activated.
    /// A second activation means a discarded instance came alive, and it would then handle
    /// player notifications against an `AppStore` that nothing else reads — correct-looking
    /// behaviour driven by state no view can see.
    ///
    /// That is invisible in every other way. It went unnoticed until a queue log line
    /// reported metadata as cached and the very next line fetched it anyway; see
    /// `plans/logged-in-view-init-side-effects.md`.
    ///
    /// **This only covers services that call it.** A new service that subscribes inside its
    /// own `init` is not protected, because it never reaches an `activate()` to report from
    /// — that pattern is the thing to avoid, not something this can detect.
    @MainActor
    func recordActivation(_ service: AnyObject) {
        let name = String(describing: type(of: service))
        let id = ObjectIdentifier(service)
        defer { activatedServices[name] = id }

        guard let previous = activatedServices[name], previous != id else { return }
        debugLog(
            name,
            "WARNING: a second instance was activated — a discarded one came alive. "
                + "Construction must stay inert; only the instance SwiftUI kept may be activated.",
        )
    }
#else
    @inlinable
    @MainActor
    func recordActivation(_: AnyObject) {}
#endif
