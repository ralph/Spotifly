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

- [ ] **B1a. Teach the probe to print the CDN url and the AES key.** *The probe cannot supply
      them today*, so this step comes first or B1b has nothing to fetch. `-show-token` prints
      the access token only, and the storage-resolve step at `libspot-probe/main.go:238`
      resolves the urls and then prints `"%s, %d cdn url(s)"` — the format and the **count**,
      discarding the urls themselves. It already holds what is needed; it just never says it.
      Add an output mode that prints the selected url and the key.
      **Warning: the probe shares the app's grant, and running it revokes Spotifly's refresh
      token** — expect to sign in again afterwards, and do not run it in the middle of other
      work that depends on being signed in.
- [ ] **B1b. Fetch the file** from the CDN url.
- [ ] **B1c. Decrypt it — and mind the keystream offset.** AES-CTR over the file, then drop
      the first **167 plaintext** bytes.
      **Do not drop 167 encrypted bytes and start the cipher at the initial IV.** That is the
      natural reading of "skip the 167-byte header" and it silently produces a corrupt Ogg
      stream: byte 167 would be decrypted with keystream byte 0, so every byte is wrong while
      nothing errors. librespot decrypts from byte zero and only then exposes a subfile
      beginning at `0xa7` (= 167). Either decrypt the whole file and then drop 167 plaintext
      bytes, or seek **both** the input and the CTR keystream to 167.
- [ ] **B1d. Decode it** through libvorbis or tremor. **C dependencies are acceptable; Rust and
      Go are not** — the entire point is removing a non-Swift toolchain, so reintroducing one
      defeats it.
- [ ] **B1e. Write a WAV and listen to it.** The success criterion is that it *sounds correct*.
      Not that it decodes without error — a decoder can produce plausible garbage.
- [ ] **B1f. Measure the speed — on a release build.** Decoding must run comfortably faster
      than realtime on one core. Record the actual multiple rather than a pass/fail: "3×
      realtime" and "1.1× realtime" are both passes by the letter and only one is a pass in
      practice.
      **Build optimized, and say so in the result.** A default Swift/Xcode configuration is
      unoptimized, and this measurement can close Track B *permanently* — retiring the whole
      idea on a debug build's numbers would be the worst outcome this plan can produce.
      Release-optimize the Swift program and the C dependency, and record the build mode and
      the hardware next to the multiple, so the number can be re-read later rather than
      re-trusted.

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
- [ ] The decode-speed multiple is recorded as a number, **with the build mode and hardware
      beside it** — a release build, not the default configuration
- [ ] No Rust or Go was introduced *into the spike*. B1a edits the existing Go probe, which is
      a tool rather than a dependency, and does not count against this
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
- **The same error in reverse: a debug build read as a fail.** This decision is permanent, so
  an unoptimized measurement can retire Track B on a number that was never real. B1f requires
  a release build for exactly this reason.
- **A corrupt stream mistaken for "Vorbis in Swift does not work."** The keystream-offset trap
  in B1c produces garbage that looks like a decoder failure. If the audio is wrong, re-check
  the decryption alignment before concluding anything about the decoder.
- **Losing the sign-in mid-task**, per B1a. Run the probe deliberately, not casually.
- **The result is a decision, and decisions expire.** If this sits unanswered for months, the
  branch it depends on drifts; note the date on whatever answer lands.
