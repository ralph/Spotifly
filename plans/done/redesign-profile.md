# Redesign: Profil

Status: **Done**, 2026-10-21, PR #216. Twelfth of the stacked redesign PRs. Signing out itself is
not tried: it would need a new sign-in, which is the user's
Components: `Spotifly/Views/UserProfileView.swift`, `Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Profil"),
`design/native/Screens.jsx` (`NProfile`)

## Summary

The profile becomes the handoff's grouped form: avatar and name centred over a "Konto" section
(Anzeigename, Benutzer-ID to select or copy, Profil im Web), a section with "Konto verwalten" and
the app's settings, and "Abmelden …" under it.

## Problem

The profile shows "Angemeldet als …", the user id in a group box, and two buttons: open in
Spotify and log out.

## Solution

### API

Nothing new: `UserProfile` (`profileAttributes`) has the display name, the id, the image and
the web link. "Konto verwalten" opens Spotify's account page,
`https://www.spotify.com/account/overview/`, in the browser: subscription, payment and privacy
are managed there, as the section's footer says. No stats, plan or country, as the handoff has
it.

### Page

- Centred: the 96 pt avatar (`ProfileAvatarView`), the display name in the title style.
- `Form(.grouped)`, section "Konto": "Anzeigename"; "Benutzer-ID", the id selectable, in a
  monospaced font, with a borderless copy button; "Profil im Web", a `Link` showing the
  `open.spotify.com/user/…` address.
- A section with the footer "Abo, Zahlungsdaten und Datenschutz verwaltest du in deinem
  Spotify-Konto.": "Konto verwalten" with a bordered "In Spotify öffnen", and
  "App-Einstellungen" with a `SettingsLink` "Einstellungen …".
- "Abmelden …", destructive, centred, now behind a confirmation, as its "…" says.
- **Without a profile** (a revoked grant), the page still says so and still offers Abmelden
  and the settings: nothing here may depend on a request having succeeded.

## Verification

- Build, unit tests.
- Run the Debug build: the page with a profile; copy the id; open Abmelden's confirmation and
  cancel it (signing out would need a new sign-in, which is the user's to do); Einstellungen
  opens the settings window.

### Result

- Live: the page as the handoff draws it, the avatar and name without a card (the header of an
  empty section) and Abmelden in red under the footer; the copy button put the user id on the
  pasteboard; Abmelden's confirmation opened and was cancelled; Einstellungen opened the
  settings window.
- `/simplify`: one `NSPasteboard.copy` for the three places that copy; `playerBarClearance()`
  for every form and table, which gave recent searches and the profile the bar's room they
  lacked; the form at its own width, as Speakers has it; the English "Logout" now "Log Out",
  matching the row. Not taken: dropping the name row, the copy button or the settings row,
  which the handoff asks for.
- `/code-review` raised the hard-coded red and the empty-section header, both kept for the
  design; Codex found nothing.
