//
//  ActivationRegistry.swift
//  Spotifly
//
//  Debug guard against a discarded service coming alive.
//

import Foundation

#if DEBUG
    /// Holds the previously activated instance without keeping it alive.
    ///
    /// A weak reference is what makes the check mean "is the earlier instance *still
    /// live?*" rather than "was there an earlier instance?". Both halves matter: logging
    /// out and back in legitimately builds new services, and identity alone would call that
    /// a fault; conversely an `ObjectIdentifier` is only unique among live objects, so a
    /// freed one can be reused by a new allocation and hide a real duplicate.
    private final class WeaklyHeldService {
        weak var object: AnyObject?
        init(_ object: AnyObject) {
            self.object = object
        }
    }

    /// The instance of each service type activated most recently.
    @MainActor private var activatedServices: [String: WeaklyHeldService] = [:]

    /// Warns when a *second* instance of a service goes live.
    ///
    /// A `LoggedInSession` makes one of each service, and the app holds one session at a time,
    /// so a second live activation means a second session is alive. It would then handle player
    /// notifications against an `AppStore` that nothing else reads — correct-looking behaviour
    /// driven by state no view can see. Services were once a view's `@State`, built in several
    /// copies by SwiftUI's repeated `init`, which is how this was found.
    ///
    /// That is invisible in every other way. It went unnoticed until a queue log line
    /// reported metadata as cached and the very next line fetched it anyway; see
    /// `plans/done/logged-in-view-init-side-effects.md`.
    ///
    /// **This only covers services that call it.** A new service that subscribes inside its
    /// own `init` is not protected, because it never reaches an `activate()` to report from
    /// — that pattern is the thing to avoid, not something this can detect.
    @MainActor
    func recordActivation(_ service: AnyObject) {
        let name = String(describing: type(of: service))

        // The owner is the first activated instance that is *still* live, not the most
        // recent one. Overwriting on every call would lose the owner as soon as an
        // offending instance was itself released, and a third activation alongside the
        // still-live owner would then pass unreported.
        defer {
            if activatedServices[name]?.object == nil {
                activatedServices[name] = WeaklyHeldService(service)
            }
        }

        // A released predecessor is not a fault: logging out ends the session, and the next
        // sign-in rightly builds fresh services.
        guard let previous = activatedServices[name]?.object, previous !== service else { return }
        debugLog(
            name,
            "WARNING: a second instance was activated while the first is still live — "
                + "a second session is alive. Construction must stay inert, and the app "
                + "holds one session at a time.",
        )
    }
#else
    @inlinable
    @MainActor
    func recordActivation(_: AnyObject) {}
#endif
