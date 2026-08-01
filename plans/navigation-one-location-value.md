# Navigation: make the location one value

Status: **planned**
Components: `Spotifly/ViewModels/NavigationCoordinator.swift`, `Spotifly/Store/AppStore.swift`,
`Spotifly/Views/LoggedInContentRouterView.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Views/LoggedInToolbars.swift`, `SpotiflyTests/SpotiflyTests.swift`
Found: 2026-08-01, while deciding what to do about two long-failing navigation tests

## Requirements

1. The back/forward control is visible everywhere in the app, except views that are not part
   of the shell — login, the premium and whitelist blockers, and the mini player (see
   below).
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

This test's expectation changes, and that is a deliberate product decision rather than a
technical one.

It asserts that after startpage → search → clear → startpage there is **nothing to go back
to**. That was defensible while a cleared search left a dead route behind: the entry could
not be rendered, so removing it was the only honest option. With results kept per query
(§1b) the route stays renderable, so Back returns to the search results — which is what
requirement 2 asks for and how a browser behaves. Clearing a search field has never meant
erasing where you have been.

It also fails today for a mechanical reason worth recording, because the same defect would
bite elsewhere: `pruneSearchHistory` removes entries whose *own* section is `.searchResults`,
but the recorded entry is the `startpage` one that led into search — so nothing is pruned
and history keeps an entry equal to where the user now is. Back becomes a no-op that still
advertises itself. That missing collapse is fixed regardless (§1a); it is simply no longer
reachable through this scenario.

**So this test is rewritten and renamed**, asserting that Back after clearing returns to the
search results. It is the one existing expectation this plan overturns.

## Design

### 1. One `Route` value

Introduce a single value that answers "where is the user":

```swift
struct Route: Hashable {
    var section: NavigationItem?       // nil is "nothing selected", a real state
    var selection: Selection?          // which entity this section is showing
    var query: String?                 // the submitted search, when section is .searchResults
    var path: [NavigationDestination]  // drill-down
}
```

**The query is part of the location.** Searching again while already on `.searchResults`
changes nothing about section, selection or path — the route would be equal to itself, so
nothing records and Back could never return to the earlier results, while
`AppStore.searchResults` has already replaced them. Two searches are two places, and the
query is what distinguishes them.

### 1b. Results keyed by query

`AppStore.searchResults` holds one result set. Replace it with results keyed by the query
that produced them, bounded to the most recent handful.

This is the piece that makes the rest cheap, and it collapses three separate problems into
one small change:

- **Restoring a search route needs no fetch.** Back to `search("a")` reads `a` from the
  cache. No loading state for a restored route, no retry path when the network is down, and
  no superseded-write guard — which matters, because `SearchService` opens with
  `guard !store.searchIsLoading else { return }` and would otherwise drop the newer of two
  rapid restorations while the older one wrote. Re-running the query on Back would have
  needed all three; caching needs none of them.
- **The query/results association stops being ad-hoc.** A single result set records nothing
  about what produced it, and `searchText` is view state that drifts — type "ab" without
  submitting and it no longer describes what is shown. Reopening Search Results from the
  sidebar could not tell which query the visible results belong to. Keyed storage *is* that
  association; no separate field to keep in step.
- **Search leaves the invalidation path.** A search route is renderable whenever its results
  are cached, so clearing the field no longer makes history entries dead.

The bound is what keeps this honest. A session with many searches cannot grow without
limit, so the cache keeps the last few queries and evicts the oldest — and an evicted
query's route *does* become unviewable, handled by the same invalidation in §1a that covers
a playlist deleted while it sits in history. One mechanism, two triggers, instead of a
mechanism whose only real trigger was search.

Clearing the search field then means what it says: it clears the field and leaves the
results view. It does not evict the cache, and it does not erase where the user has been.

One more piece of state comes with the cache: **which query is currently displayed.** The
cache says what "a" and "b" produced, not which of them the user is looking at, and the most
recently *inserted* key is the wrong answer — after search "a" → search "b" → Back to "a" →
Albums, the newest key is "b" while the results on screen were "a"'s. Reopening Search
Results from the sidebar has to land on "a".

So the store tracks the last displayed query, updated whenever a search route is shown —
including when one is restored by Back. The sidebar entry builds its route from that, which
is what makes it agree with what the user last saw rather than with what was fetched last.

**`Selection` is an entity reference, nothing more** — a kind and an id. It deliberately
does *not* record whether the item was in the library, even though today's
`selected*Id` / `viewing*Id` split does exactly that.

Membership changes on its own: save an ephemeral album, follow an artist, and only
`AppStore` learns about it. A flag captured in the route would then be stale in `current`,
in every history entry, and in the memo — and selecting the same entity from its now-library
row would produce a route that compares as *different*, adding a Back step that visibly goes
nowhere. Library membership is derived from the store at render time, where it is always
current. It describes how to present a place, not which place it is.

**The section stays optional.** `SidebarView` binds a `NavigationItem?` to
`List(selection:)`, so macOS can clear the selection, and the router already renders that
case deliberately — `case .none` shows the localized `empty.select_item` placeholder. It is
a designed screen, not a gap.

A non-optional section would leave the projection binding with nothing sensible to do when
SwiftUI writes `nil`: ignore it and the sidebar deselects visually while the content stays,
or substitute a default and the app navigates somewhere the user did not ask for. Keeping it
optional means "nothing selected" is simply another location — it records into history and
back returns from it like anywhere else, which is what requirement 2 asks for.

Removing the empty state altogether is a defensible product change, but a separate one; it
should not arrive as a side effect of this refactor.


**Remembered selections are not part of the route.** Today `selectedAlbumId`,
`selectedArtistId` and `selectedPlaylistId` coexist and survive section switches —
`selectNavigationItem` clears only the `viewing*Id` shadows — so Albums(A) → Artists →
Albums returns to A rather than auto-selecting the first album. A single `Selection?` on the
route would lose that, and the user would land on a different album than the one they left.

That property is worth keeping, but it does not belong in the location. Keep it as a
separate `lastSelection: [NavigationItem: Selection]` memo on the coordinator, consulted
when entering a section without an explicit target and updated whenever a selection changes.

The memo does not participate in `Route` equality, and therefore does not affect history at
all: two moments that differ only in which album Albums *would* reopen to are the same
location. Only actually being somewhere counts. Were the memo part of the route, selecting
an album would retroactively make every unrelated section visit look like a new place.

The coordinator then holds `current: Route`, plus `back: [Route]` and `forward: [Route]`.
Everything else is derived:

- `canNavigateBackward` = `!back.isEmpty` — unchanged, but now it means what it says;
- `title(for:)` becomes a function of one `Route`, with no field-precedence guessing;
- "is this the same place" is `==` on `Route`;
- recording is `back.append(old)` on any change, with two operations instead of a heuristic
  family — see below.

### 1a. Two ways to move: navigate, and replace

Most movement is a **navigation**: `back.append(current)`, `current = new`, clear forward.
Revisiting a place you have been is still a navigation — startpage → albums → startpage
keeps both startpage entries, because requirement 2 says back must replay
albums → startpage.

The exception is when a route stops being *viewable at all*: a playlist deleted while it
sits in history, or a search whose query has been **evicted from the cache**. Note that
clearing the search field is *not* one of these — §1b keeps those results, so the route
stays renderable. Requirement 2 is about steps the user took, and only a step that can no
longer be displayed drops out.

This is not only about the current route. A dead entry can sit anywhere in either stack —
`startpage → playlist → albums → that same playlist`, then delete it, and a Back press two
steps along would land on an empty view. Handling only `current` would leave that.

So invalidation operates on the whole history at once. Treat it as one sequence,
`back + [current] + forward.reversed()`, and:

1. drop every entry that is no longer viewable;
2. collapse runs of equal adjacent entries — removing a node can join two entries that are
   the same place, and stepping between them would be a no-op;
3. re-derive `back`, `current` and `forward` around the surviving current position. If the
   current route itself was dropped, the nearest surviving entry backwards becomes current.

Stated over the sequence rather than per-stack, this is one operation with one description,
and it is what the existing `pruneSearchHistory` was reaching for — it only ever removed
entries whose own section was `.searchResults`, and never collapsed what that left behind.

Note step 2 is deliberately *adjacent* runs, not a scan for duplicates. An earlier entry
equal to the current route is legitimate: startpage → albums → startpage must keep both
startpage entries so Back can replay albums.

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

**A pop is not a new route.** The same binding carries both directions: `NavigationStack`
writes a *shorter* path when its own back chevron is used. Recording that as a new location
would push the popped route onto the back stack, so the toolbar's Back would then walk
*forward* into the view just left — a loop between two entries instead of moving backward.

So the binding's setter has to classify the write before recording it:

- the new path extends the old one → a push, record normally;
- the new path is a prefix of the old one → a pop, route it through the same back
  navigation the toolbar uses, so both affordances share one history;
- anything else → treat as a new location.

This is the one place where the two navigation systems genuinely have to be reconciled, and
it is worth doing explicitly rather than letting a native gesture desynchronise the history.

### 4. Replace `pendingSectionNavigation` with a method

`navigateToAlbumSection(albumId:)` and friends set a pending request that
`LoggedInView.onChange` observes and hands back. With a single route, they can apply
directly. This removes a state field, an `.onChange`, and a class of "observed mid-flight"
bugs.

### 5. Requirement 1: verify before building

`LoggedInContentToolbar` — which hosts the back/forward control — is attached to
`contentRouter`, and `contentRouter` renders in every non-blocking, non-mini state. So the
control is likely already present everywhere the requirement asks for.

**The mini player is exempt, by decision.** In mini-player mode `mainAppView` renders only
`NowPlayingBarView`, with no window toolbar at all. That is not an oversight: the mini
player is a compact always-on-top window for transport control, it shows no navigable
content, and there is nothing in it to go back *from*. Adding the control would mean adding
a toolbar to a window whose whole point is not having one.

This is recorded as a decision rather than left open, because "it is a product question"
would let an implementation skip it and still claim the requirement. If Ralph wants the
control there, it changes the mini player's design, not this plan's.

One case still to check at runtime: the **3-column layout**, where a second toolbar
(`LoggedInDetailToolbar`) is attached alongside the content one. Confirm both merge into a
single window toolbar rather than one replacing the other.

If that holds, requirement 1 needs no code, and the plan should say so rather than invent
work.

## Tests

The current navigation tests construct a coordinator and drive it directly, which is the
right shape and should stay. What is missing is coverage of the *contract*, not of
individual field assignments.

Fix the two existing tests by fixing the code they pin:

1. `favorites selection …` — back title names the place the entry returns to.
2. `clearing search …` — **rewritten and renamed.** Clearing the field leaves history
   intact; Back returns to the search results, which are still cached.

Add, all against the coordinator alone:

3. Every user-initiated change is reachable by back — a scripted walk of a dozen steps
   across sections, selections and drill-downs, then back the same number of times, ending
   where it started. This is requirement 2 as an assertion, and nothing tests it today.
4. Forward is cleared by a new navigation after going back.
5. Going back and forward returns to the identical route, including drill-down.
6. Automatic first-item selection on entering a section is not recorded.
7. A drill-down performed through the stack binding records history.
8. A **native pop** through the stack binding moves backward rather than recording a new
   route: pop from B to A, then press Back, and the result is the entry before A — not B.
9. Entering a section again returns to the selection left behind, and that memo does not
   itself create history entries: Albums(A) → Artists → Albums lands on A, and back from
   there leaves the section rather than undoing a re-selection.
10. Back title and forward title name the target route, for a section, a selection, and a
    drill-down, including when the entity is absent from the store.
11. The history cap holds — the oldest entries are dropped and back still works.
12. Restoring a route does not itself record history.
13. Clearing the sidebar selection is a location: it records, renders the empty state, and
    back returns from it.
14. Revisiting a route keeps both entries: startpage → albums → startpage, then back twice,
    replays albums and then startpage. This is the case the adjacent-only collapse must not
    swallow.
15. Invalidation reaches the whole history, not just the current route. A playlist deleted
    while it sits in both stacks is gone from each, with no back step landing on an empty
    view — and so is a search whose query has been evicted from the cache.
16. Invalidation collapses what it joins: an entry removed from between two equal routes
    leaves one, not two.
17. Two consecutive searches are two locations and both are reachable: search "a", search
    "b", then back shows "a"'s results, and forward shows "b"'s again.
20. Reopening Search Results from the sidebar adopts the query the visible results came
    from, not whatever is currently typed in the field.
21. The results cache is bounded: after more searches than it holds, the oldest query is
    evicted and its route is invalidated rather than rendering empty.
18. Library membership is not identity: viewing an ephemeral album, saving it, then
    selecting it from the library row is the same route and adds no back step.

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
4. Search, clear the search field, then press back: it returns to the search results,
   served from the cache with no new request. This is the behaviour change named in
   §"clearing search".
5. Enter a section whose first item auto-selects; back leaves the section rather than
   undoing the auto-selection.

## Acceptance criteria

- One value describes the location; the coordinator's public fields are projections of it.
- Every user-initiated navigation is reachable by back, and `canNavigateBackward` is false
  only at the true start of history.
- Back and forward titles name the route they lead to, and never a section the entry is not
  in.
- Back is never a no-op: `back.last` is never equal to the current route, and no reachable
  entry renders an empty view.
- A search route is served from the cache, without a request, for as long as its query is
  held; once evicted it is invalidated rather than shown empty. Entries further back may equal it — a revisited place is a
  real step and must stay replayable.
- The stack's own back chevron and the toolbar's Back move through the same history: a
  native pop does not become a forward entry.
- Re-entering a section returns to the selection left behind, and that memo neither appears
  in `Route` equality nor creates history entries.
- The back/forward control is visible throughout the shell. The mini player is exempt by the
  decision recorded above, not by omission.
- `pendingSectionNavigation` is gone.
- The full Swift test suite passes with no excepted failures.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.

## Out of scope

- **Restoring navigation across launches.** A `Codable` route makes it possible and it is a
  reasonable follow-up, but it needs its own decisions about what should be restored.
- **URL / deep-link parsing.** `spotify:` link handling is a separate feature; a single route
  value makes it cheaper later, which is a reason to do this first, not to widen it now.
- **Reworking the split-view layout.** The 2- vs 3-column switch stays as it is.
