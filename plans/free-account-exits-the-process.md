# A non-premium account terminates Spotifly

Status: **not started** — recorded from a code reading, **not observed**
Components: `librespot/core/src/session.rs`, `librespot/connect/src/spirc.rs`,
`rust/src/lib.rs`, and whatever Swift would show instead
Found: 2026-08-13, while looking for a source for the product type after
`profileAttributes` turned out not to carry one

## The finding

librespot ends the process for any account whose product type is not `premium`
(`core/src/session.rs:364`):

```rust
fn check_catalogue(attributes: &UserAttributes) {
    if let Some(account_type) = attributes.get("type") {
        if account_type != "premium" {
            error!("librespot does not support {account_type:?} accounts.");
            info!("Please support Spotify and your artists and sign up for a premium account.");

            // TODO: logout instead of exiting
            exit(1);
        }
    }
}
```

Not an error, not a callback — `std::process::exit`. librespot is linked into the app, so this
is Spotifly quitting.

**Three call sites, all reachable from this app:**

| Call site | Reached by |
| --- | --- |
| `session.rs:847`, the `ProductInfo` mercury handler | every connect — the accesspoint pushes it |
| `session.rs:612` `set_user_attributes` | `connect/src/spirc.rs:947` |
| `session.rs:600` `set_user_attribute` | `connect/src/spirc.rs:965` |

The app connects a full `Session` and runs Spirc, so all three are live. The first fires at
sign-in; the other two mean a **mid-session** attribute push carrying `type` can end the process
while the user is doing something else. Only a payload containing the `type` key triggers it —
`check_catalogue` returns without acting when the key is absent, which is why routine attribute
pushes are harmless.

## Confidence, honestly

**This has not been reproduced.** It is read off the source, and reproducing it needs a free
Spotify account, which nobody here has. Treat the mechanism as established and the *behaviour*
as inferred: what a user actually sees — an immediate quit, a quit after the window appears, a
hang — has not been watched.

The revision read is the local checkout, `v0.8.0-16-g9c7d756` on `dev`. The `exit` predates it
(`e748d54`, "Check availability from the catalogue attribute"). **Upstream `dev` beyond this
checkout was not checked**, and the `TODO` suggests the maintainers already consider it wrong,
so the first thing to do is look whether it has since been fixed.

## Why it matters more than it looks

It is the only handling a free account gets. `PremiumRequiredView` used to exist for exactly
this case and was deleted in ff87034, because it could never have run: the process is gone
before any screen draws. So the app has no story here at all — not a bad one, none.

It is also invisible in the failure reports we would get. A user whose app "just closes when I
log in" has no error to send, and nothing in Spotifly's own logs explains it; the message goes
to librespot's `error!` and the exit code is 1.

## Shape of the fix

The workspace is already set up for this: `spotifly-code/rust/Cargo.toml` uses path dependencies
on `../../librespot` with **no revision pin**, precisely so a local patch can be checked out and
built (see the workspace `CLAUDE.md`).

1. **Check upstream first.** If `dev` has replaced the `exit` already, the fix is a checkout, not
   a patch.
2. **Make it a value, not an exit.** The product type is already carried on the session as
   `user_data().attributes["type"]` — `UserData` also holds `country` and
   `canonical_username` — so surfacing it costs no request and no new endpoint. The accesspoint
   pushes it at connect.
3. **Let Swift decide.** An FFI in the same shape as `spotifly_last_grant_account` hands the type
   up, and the app shows a screen and offers logout rather than vanishing. That is the screen
   ff87034 deleted, and it should be written back only once something can actually reach it.
4. **Upstream it.** The `TODO` invites exactly this change, and a patch that returns an error
   instead of exiting is useful to every embedder, not just this one.

Worth deciding before starting: whether Spotifly should refuse a free account outright or let it
browse without playback. The app is a Connect device and streaming is premium-only, but
everything else it does — library, search, playlists, driving *another* device — runs on the
keymaster grant and has nothing to do with the product type. That is a product question, and the
patch above is what makes either answer possible.
