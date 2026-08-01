# Navigation: make the location one value

Status: **planned**
Components: `Spotifly/ViewModels/NavigationCoordinator.swift`,
`Spotifly/Views/LoggedInContentRouterView.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Views/LoggedInToolbars.swift`, `SpotiflyTests/SpotiflyTests.swift`
Found: 2026-08-01, while deciding what to do about two long-failing navigation tests

## Requirements

1. The back/forward control is visible everywhere in the app, except views that are not part
   of the shell — login, the premium and whitelist blockers.
2. Back always works when there is somewhere to go back to. A step the user took should not
   be missing from history because a heuristic decided it did not count.

## How navigation works today

Three layers hold the location, and only one of them is a SwiftUI navigation construct:

| Layer | State | Bound to |
| --- | --- | --- |
| Sidebar section | `selectedNavigationItem: NavigationItem?` | `NavigationSplitView` sidebar selection |
| List selection | `selectedAlbumId` / `selectedArtistId` / `selectedPlaylistId` | the third column in the 3-column layout |
| Drill-down | `navigationPath: [NavigationDestination]` | `NavigationStack(path:)` |

Plus `viewingAlbumId` / `viewingArtistId` / `viewingPlaylistId`, which shadow the selection
for items that are not in the user's library.

Eight mutable variables, changed independently, and no single value that says where the user
is.

On top of that sits a **second, parallel history**: `navigationBackStack` and
`navigationForwardStack` of `NavigationSnapshot`, a struct holding all eight fields.
`NavigationStack` maintains its own path and would provide a native back affordance; the
toolbar's back button does not use it. It calls `applyNavigationSnapshot`, which rewrites
all eight fields at once, driving the stack from outside.

So the app has two navigation systems that do not know about each other.

## Does SwiftUI have a router with paths?

Yes, and the app already uses the modern form of it — for one of the three layers.

`NavigationStack(path:)` takes a binding to a typed array (or a type-erased
`NavigationPath`), and `.navigationDestination(for: Type.self)` maps a value to a view.
Pushing is `append`, going back is `removeLast`, and a deep link is assigning a whole array.
That is a router with a typed path; `LoggedInContentRouterView` does exactly this with
`[NavigationDestination]`.

What SwiftUI does **not** provide is URL parsing or a route table keyed by strings. There is
no `/albums/:id` matcher. The equivalent is a `Hashable` (and, if you want restoration,
`Codable`) enum — which `NavigationDestination` already is.

So the answer to "should we adopt a router?" is: the router is already here. The problem is
that only the drill-down goes through it, while the section and the list selection are
separate state that history has to reconstruct by hand.

## Assessment

What is already right, and should survive any refactor:

- value-based `navigationDestination`, not the deprecated `NavigationLink(destination:)`;
- a single coordinator rather than navigation state scattered across views;
- `NavigationSplitView` for the macOS three-column idiom.

What works against the two requirements:

1. **The location is eight variables, not one value.** Every derived question — what is this
   entry called, is this the same place, does this transition count — is answered by
   heuristics over a tuple. Both failing tests are failures of exactly those heuristics.
2. **History is lossy on purpose.** `shouldRecordNavigationChange` drops transitions it
   classifies as implicit, and `pruneSearchHistory` deletes entries outright. Requirement 2
   says a step the user took should be reachable; a filter that guesses which steps "count"
   cannot promise that.
3. **Two histories.** `NavigationStack` has a path with its own back semantics; the snapshot
   stacks have another. They are reconciled by overwriting the path.
4. **`viewing*Id` shadows `selected*Id`.** Three more fields whose interaction with the
   selection is only expressed as assignments scattered through the coordinator.
5. **`pendingSectionNavigation` is a request/observe round trip.** A caller sets it, the view
   layer observes it in `.onChange` and calls back into the coordinator, which clears it. A
   method call would do, and the intermediate state is one more thing history can observe.
6. **Switching section clears the drill-down.** Going to Favorites and back only restores the
   drill-down because the snapshot happened to be recorded.

## The two failing tests are symptoms, not flakes

Both have failed since before the test target was buildable. Each pins a real defect, and
neither is fixed by adjusting the test alone.

### `favorites selection clears drill down state and still records section history`

The snapshot is the Albums section holding an *artist* drill-down. `title(for:)` looks at
`navigationPath.last` first, finds `.artist(id:)`, cannot resolve the artist in the store,
and falls back to `NavigationItem.artists.title` — so the back button says **"Artists"**, a
section the user was never in. The test expects "Albums".

The defect is the fallback: when a drill-down target is unknown, it names the destination's
*type* rather than the place the entry would return to. Falling back to the snapshot's own
section is the correct behaviour, and it is what the test asserts.

### `clearing search prunes search history entries`

The sequence is startpage → search → startpage. `pruneSearchHistory` removes entries whose
own section is `.searchResults`; the recorded entry is the *startpage* one that led into
search, so nothing is pruned. History then holds an entry identical to where the user
already is, and back is a no-op that still reports as available.

The defect is a missing collapse, not a missing prune: removing a node from a path should
collapse the neighbours it joined if they are now the same place.

Note that the test's *name* suggests deleting the pre-search entry too. That would conflict
with requirement 2 — after clearing search you should still be able to go back to where you
were before searching. The plan keeps the entry and removes the duplicate.

## Design

### 1. One `Route` value

Introduce a single value that answers "where is the user":

```swift
struct Route: Hashable {
    var section: NavigationItem
    var selection: Selection?          // album / artist / playlist id, per section
    var path: [NavigationDestination]  // drill-down
}
```

with `Selection` carrying whether the item is a library selection or an ephemeral visit, so
`viewing*Id` disappears as separate state rather than being renamed.

The coordinator then holds `current: Route`, plus `back: [Route]` and `forward: [Route]`.
Everything else is derived:

- `canNavigateBackward` = `!back.isEmpty` — unchanged, but now it means what it says;
- `title(for:)` becomes a function of one `Route`, with no field-precedence guessing;
- "is this the same place" is `==` on `Route`;
- recording is `back.append(old)` on any change, with **one** rule instead of a heuristic
  family: collapse when the new route equals the current one.

The eight fields do not vanish from the API — `NavigationSplitView` needs bindings for the
section and the list selection. They become computed projections into `current`, so there is
one source of truth and several views onto it.

### 2. Record every user-initiated change

Requirement 2 is a statement about recording policy. Replace
`shouldRecordNavigationChange` and `isImplicitLibraryAutoSelection` with:

- record when the route changed and the change came from the user;
- do not record when the change came from restoring history (already handled by
  `historyRestoreTarget`, which stays);
- do not record an automatic first-item selection — but express that at the *call site* that
  performs it, not as a pattern-match on two snapshots afterwards.

That last point is the substance of the change: the coordinator currently has to infer
intent from state; it should be told.

### 3. Keep `NavigationStack` as the drill-down renderer

Do not try to push sections onto the `NavigationStack`. The macOS shell is a split view; the
section is a sidebar selection, not a stack entry, and modelling it as one would fight the
platform.

`Route.path` stays bound to `NavigationStack(path:)`. The gain is that the binding now reads
and writes *through* the route, so a drill-down performed by the stack itself — a
`NavigationLink` inside a list — records history like any other change, which today it does
not.

### 4. Replace `pendingSectionNavigation` with a method

`navigateToAlbumSection(albumId:)` and friends set a pending request that
`LoggedInView.onChange` observes and hands back. With a single route, they can apply
directly. This removes a state field, an `.onChange`, and a class of "observed mid-flight"
bugs.

### 5. Requirement 1: verify before building

`LoggedInContentToolbar` — which hosts the back/forward control — is attached to
`contentRouter`, and `contentRouter` renders in every non-blocking, non-mini state. So the
control is likely already present everywhere the requirement asks for.

Two cases to check at runtime before assuming work is needed:

- **mini-player mode**, where `mainAppView` renders only `NowPlayingBarView` and there is no
  window toolbar. Deciding whether the requirement applies here is a product question: the
  mini player is deliberately chrome-less.
- the **3-column layout**, where a second toolbar (`LoggedInDetailToolbar`) is attached
  alongside; confirm both merge into one window toolbar rather than one replacing the other.

If both hold, requirement 1 needs no code and the plan should say so rather than invent
work.

## Tests

The current navigation tests construct a coordinator and drive it directly, which is the
right shape and should stay. What is missing is coverage of the *contract*, not of
individual field assignments.

Fix the two existing tests by fixing the code they pin:

1. `favorites selection …` — back title names the place the entry returns to.
2. `clearing search …` — history holds no entry equal to the current location.

Add, all against the coordinator alone:

3. Every user-initiated change is reachable by back — a scripted walk of a dozen steps
   across sections, selections and drill-downs, then back the same number of times, ending
   where it started. This is requirement 2 as an assertion, and nothing tests it today.
4. Forward is cleared by a new navigation after going back.
5. Going back and forward returns to the identical route, including drill-down.
6. Automatic first-item selection on entering a section is not recorded.
7. A drill-down performed through the stack binding records history.
8. Back title and forward title name the target route, for a section, a selection, and a
   drill-down, including when the entity is absent from the store.
9. The history cap holds — the oldest entries are dropped and back still works.
10. Restoring a route does not itself record history.

Deep-link entry points (`navigateToAlbumSection` and friends) get one test each showing the
route they produce, replacing what the `pendingSectionNavigation` round trip made awkward to
test.

## Verification

### Automated

```text
xcodebuild -scheme Spotifly -configuration Debug build
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' \
  -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES
```

The whole suite must pass. This is the first change on this branch that may claim that: the
two navigation failures are the only ones outstanding, so after this there is no baseline to
except.

### Runtime

1. Walk: startpage → albums → pick an album → drill into its artist → favorites → search →
   a search result → back six times. Every step returns to the previous one, in order.
2. The back/forward control is present in every section, in both the 2- and 3-column
   layouts.
3. Forward after several backs replays the same route.
4. Search, clear the search, then press back: it goes where you were before searching, not
   to a dead entry.
5. Enter a section whose first item auto-selects; back leaves the section rather than
   undoing the auto-selection.

## Acceptance criteria

- One value describes the location; the coordinator's public fields are projections of it.
- Every user-initiated navigation is reachable by back, and `canNavigateBackward` is false
  only at the true start of history.
- Back and forward titles name the route they lead to, and never a section the entry is not
  in.
- No history entry is equal to the current location.
- The back/forward control is visible throughout the shell, with the mini player decided
  explicitly rather than by omission.
- `pendingSectionNavigation` is gone.
- The full Swift test suite passes with no excepted failures.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.

## Out of scope

- **Restoring navigation across launches.** A `Codable` route makes it possible and it is a
  reasonable follow-up, but it needs its own decisions about what should be restored.
- **URL / deep-link parsing.** `spotify:` link handling is a separate feature; a single route
  value makes it cheaper later, which is a reason to do this first, not to widen it now.
- **Reworking the split-view layout.** The 2- vs 3-column switch stays as it is.
