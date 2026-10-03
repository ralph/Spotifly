# The launch's connect waits for a window and two requests

Status: **Open**, small
Components: `Spotifly/Views/LoggedInLifecycleModifier.swift` (the window's task),
`Spotifly/ViewModels/AuthViewModel.swift` (`startSession`, `authorizeStreaming`)
Found: 2026-10-03, in the altitude review of `plans/done/the-session-is-attached-by-a-window.md`

## Summary

At a launch, this Mac connects to Spotify, and so appears on Spotify Connect, from the first
window's task, after the profile and the start page have loaded:
`await (profile, home)`, then `await playbackViewModel.initializeIfNeeded()`. After a sign-in it
connects at once, from `AuthViewModel.authorizeStreaming`. Two triggers, ordered differently.

## Problem

The connect needs neither request: it reads the keymaster grant, as they do. Waiting for both,
and for a window's first frame, delays this Mac's registration, and so a play on it, by however
long the slower of the two takes; a launch with no window (the app reopened with its window
closed) connects only when a window shows. The ordering dates from the Web API grant, whose
token the connect was handed (`initializeIfNeeded(accessToken:)`, before #49).

## Solution

Proposed: the session's start connects. `AuthViewModel.startSession`, which runs when the
account signs in, at launch and at a sign-in alike, starts `initializeIfNeeded()`; at a sign-in,
`authorizeStreaming`'s own call, which a renewed grant needs, coalesces with it
(`runInitialization`). The window's call stays as the retry it is for a window that reopens
after a connect failed, and says so.

## Verification

A launch before and after: the connect's `Initialization complete` against the start page's
load, and against the launch. A faked sign-in: still one connect.
