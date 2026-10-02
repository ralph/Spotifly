# A playlist's description shows Spotify's HTML

Status: **Done** 2026-10-02. Seen in the running app: a mix's links and a user description's
entities read as text; see Verification.
Components: `Spotifly/Store/EntityConversions.swift` (`normalizedPlaylistDescription`,
`String.htmlAsPlainText`)
Found: 2026-10-02, while checking a start page refresh for `plans/done/start-page-blanks-a-playlists-owner.md`

## Summary

A playlist's description is HTML, and the playlist header showed it as it came: raw links in
Spotify's mixes, and escaped characters in users' descriptions.

## Problem

Measured on 2026-10-02 with a throwaway log of the start page's playlists whose description holds
`<` or `&`:
- **Spotify's mixes** link the artists: `<a href=spotify:playlist:37i9dQZF1EIXPRB6OHORIn>Brian
  Fallon</a>, … und <a href=…>Northcote</a>`. The "The Gaslight Anthem-Mix" header showed that
  verbatim.
- **A user's description** comes escaped: "Good Vibrations OST" read `Terri Hooley&#x27;s life`.
- **Editorial text** has a bare `&`: "Die handverlesene Playlist zum Fest & Flauschig Podcast."

Only the playlist header shows a description, and Edit Details fills its field from it.

**Spotify escapes on read, not on write**, measured 2026-10-02 on the test playlist. A description
sent as `Terri's <b>test</b> & more "quoted"` came back from `fetchPlaylist` as
`Terri&#x27;s &lt;b&gt;test&lt;&#x2F;b&gt; &amp; more &quot;quoted&quot;`. The web player showed
the text as typed.

## Solution

`normalizedPlaylistDescription`, which every playlist description passes through, turns the HTML
into its text (`String.htmlAsPlainText`):
1. Tags go first. A `<` the user typed arrives escaped as `&lt;`, so a literal tag is Spotify's own.
2. Then the entities: `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;` and numeric ones (`&#39;`,
   `&#x27;`).
3. A bare `&`, or anything else that isn't an entity, stays.

The links are dropped rather than followed: the header has no place for them.

Edit Details sends the description only when it was changed, so a rename leaves it alone. The
field holds the decoded text, and since Spotify escapes on read, a changed description goes back as
typed and loses nothing.

## Verification

- **Unit tests:**
  - the measured link, entity and bare-`&` cases;
  - escaped characters coming back as typed, tags removed before entities are decoded;
  - a `<` and `>` in plain text staying, and an entity naming no character staying.
- **Live, 2026-10-02:**
  - "The Gaslight Anthem-Mix" reads "Brian Fallon, The Horrible Crowes und Northcote".
  - "Good Vibrations OST" reads "Terri Hooley's life … Belfast's punk-rock scene."
  - A description sent from the app with `'`, `<b>`, `&` and quotes read back exactly as typed,
    in the app and in the web player.
  - Renaming the test playlist in Edit Details, the description untouched, changed the name and
    left the description as it was, in the app and in the web player.
