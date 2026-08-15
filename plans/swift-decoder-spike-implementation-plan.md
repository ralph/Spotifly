# Track B1: the decoder spike that decides whether `rust/` can ever go

Parent: [`single-grant-partner-api.md`](single-grant-partner-api.md), Track B
Origin: [`librespot/swift-librespot.txt`](librespot/swift-librespot.txt), branch `origin/swift-librespot`
Status: **not started.** Branch `plan/swift-decoder-spike`.
Priority: **5 of 5.** The highest-leverage open item, and the only one whose main output is a
decision rather than a feature.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Answer one question with a measurement: **can Swift decode Spotify's audio well
enough, and fast enough, to replace librespot's playback path?**

**If the answer is no, Track B stops permanently** and librespot keeps playing music at no
cost to anything else. That is a good outcome, not a failed one. This spike exists to make the
"no" cheap and to make the "yes" trustworthy.

## Why this is worth doing at all

The `swift-librespot` branch already has the expensive parts working: Shannon cipher,
Diffie-Hellman, the AP handshake, dealer, connect state, spclient, chunked CDN download. What
it does not have is audio — `Audio/VorbisDecoder.swift` returns silence from a `TODO`, and
`AudioPipeline.swift` calls `downloadAllData()` before decoding rather than streaming, with a
comment conceding as much. Neither is an architectural dead end; both were left for last.

So the remaining unknown is narrow and testable, which is exactly what a spike is for. The
prize is deleting a 49-function FFI surface and the whole Rust interop layer — the thing that,
by the project's own account, made state sharing hard enough to motivate the Swift rewrite in
the first place.

## Scope — deliberately outside the app

**Do not wire anything into Spotifly.** This is a standalone program. Wiring it in is Task B2,
and B2 does not exist until B1 says yes.

- [ ] **B1a. Get a CDN url and AES key.** `libspot-probe -show-token` produces them.
      **Warning: the probe shares the app's grant, and running it revokes Spotifly's refresh
      token** — expect to sign in again afterwards, and do not run it in the middle of other
      work that depends on being signed in.
- [ ] **B1b. Fetch the file** from the CDN url.
- [ ] **B1c. Decrypt it.** AES-CTR, with the **167-byte header skipped**.
- [ ] **B1d. Decode it** through libvorbis or tremor. **C dependencies are acceptable; Rust and
      Go are not** — the entire point is removing a non-Swift toolchain, so reintroducing one
      defeats it.
- [ ] **B1e. Write a WAV and listen to it.** The success criterion is that it *sounds correct*.
      Not that it decodes without error — a decoder can produce plausible garbage.
- [ ] **B1f. Measure the speed.** Decoding must run comfortably faster than realtime on one
      core. Record the actual multiple rather than a pass/fail: "3× realtime" and "1.1×
      realtime" are both passes by the letter and only one of them is a pass in practice.

## The decision

- [ ] **B1g. Write the answer into `single-grant-partner-api.md` under Track B**, with the
      measurement attached. One of:
      - **Yes** — tick B1, and B2 becomes available. Do not start B2 in this branch.
      - **No** — record why, mark Track B closed, and say plainly that `rust/` stays. Then
        delete B2–B4 from the plan rather than leaving them as a standing invitation.
      - **Unclear** — say what was ambiguous and what would settle it. Do not round an unclear
        result up to a yes.

## An open question, not for this spike

Recorded in the parent plan and repeated here so it does not get lost — **and explicitly not
to be acted on before B1**:

> Spotify serves some tracks as AAC, which `AVFoundation` decodes natively. If catalogue
> coverage is good enough it may be cheaper than Vorbis for some paths.

Settle it with a measurement rather than a preference, and only after B1.

## Verification

This spike produces no app code, so the usual gates mostly do not apply. What replaces them:

- [ ] The WAV plays and sounds like the track it came from — the whole point, and not
      automatable
- [ ] The decode-speed multiple is recorded as a number
- [ ] No Rust or Go was introduced
- [ ] Nothing under `Spotifly/` or `rust/` changed — if the diff touches the app, the spike
      exceeded its scope
- [ ] The answer is written into the parent plan, whichever way it went

## Risks

- **A spike that becomes an implementation.** The failure mode is finishing B1c, feeling
  momentum, and starting to wire it into `AudioPipeline`. B2 is a separate decision with a
  separate branch.
- **"It decoded" mistaken for "it sounds right."** Listen to it.
- **A marginal speed result read as a pass.** Real playback shares a machine with the app, the
  UI and the network; 1.1× realtime on an idle core is a no.
- **Losing the sign-in mid-task**, per B1a. Run the probe deliberately, not casually.
- **The result is a decision, and decisions expire.** If this sits unanswered for months, the
  branch it depends on drifts; note the date on whatever answer lands.
