# Working on this project

Native jigsaw puzzle for macOS / iPadOS / iOS. Swift 6, SwiftUI, no dependencies,
fully offline. Read this before changing anything — it records the decisions and
the traps that are expensive to rediscover.

## Build and test

```bash
xcodebuild -project JigsawPuzzle.xcodeproj -scheme JigsawPuzzle \
  -destination 'platform=macOS,arch=arm64' -configuration Debug test
```

Swap the destination for `platform=iOS Simulator,name=iPhone 17 Pro` or
`name=iPad Pro 13-inch (M5)`. **95 tests in 9 suites must pass** before any change
is called done. Grep the output for `^✔ Test run` — xcodebuild buries it in noise.

**Every fix and feature goes into the release notes as it is made:**
`docs/Что нового в версии 1.3.md`, one line in each of the 11 languages. The
user pastes those blocks into App Store Connect, so a change missing there is
a change nobody hears about.

`./Scripts/install-mac.sh [destination]` builds Release and drops the `.app`
onto the Desktop (or wherever) so it can be launched without Xcode.

The product is named `Sasha's Puzzles.app` (`PRODUCT_NAME`), but the Swift module
and every import stay `JigsawPuzzle` (`PRODUCT_MODULE_NAME`). Do not "fix" that
mismatch — it is deliberate.

## Where things live

| Path | Role |
|---|---|
| `Sources/Engine/` | `EdgeProfile`, `PuzzleGeometry`, `PuzzleState` — pure, `Sendable`, no SwiftUI |
| `Sources/Render/` | `PieceTextureStore` — parallel bitmap cutting with the bevel |
| `Sources/Interaction/` | `Viewport`, `BoardEventView` (AppKit/UIKit input bridge) |
| `Sources/Game/` | `GameSession` plus the playing screen |
| `Sources/Library/` | Image pipeline, caches, photo import, home screen |
| `Sources/Persistence/PlayerStats.swift` | Solved-game records; streak, best times, achievements and the weekly chart are all derived from them |
| `Sources/Persistence/CloudRecordMirror.swift` | The same records in iCloud key-value storage, merged across the player's devices |
| `Sources/Game/AchievementCelebration.swift` | Achievement medals (number, stopwatch, motif or category photo) and the completion card's reveal: drop, piece burst, chime, per-medal flourish; the profile's "New" glow |
| `Sources/App/GameCenter.swift` | Friends' leaderboards and the achievement wall in Game Center, reported from `PlayerStats`; friend invitations for playing together |
| `Sources/Game/SharedTable.swift` | Playing together: one board on up to four devices, the host's device keeps it |
| `Sources/App/TableLinks.swift` | The table's two connections: `NearbyLink` (Multipeer, same room) and `MatchLink` (Game Center match) |
| `Sources/Support/Theme.swift` | Design tokens (colours, type), shared controls (`PillButton`, `RoundIconButton`, `PillSegments`), the `PuzzleMark` logo |

`Engine/` knows nothing about SwiftUI. Keep it that way — that is what
makes them unit-testable and safe to run off the main thread.

## Invariants — breaking these breaks the game

- **Neighbouring pieces share one identical curve.** Every interior cut is stored
  once; a piece's outline reuses it, reversed where the clockwise walk runs
  against the canonical direction. `GeometryTests` asserts equality at `1e-9`.
  Never generate a piece's edges independently.
- **Two pieces are joined iff their groups share a translation.** Snapping,
  merging and completion all fall out of this. Do not add per-edge connection
  bookkeeping.
- **A group at translation `.zero` is locked.** `PieceGroup.isLocked` gates
  `beginDrag`, `returnPieceToTray` and `PuzzleState.returnToTray`; a locked
  cluster is part of the finished picture and must never move again.
- **Board units are resolution independent** — board area is always
  `PuzzleGeometry.referenceArea`. Window size, zoom and orientation only change
  `Viewport`. If a resize ever loses pieces, something wrote screen units into
  the model.
- **Geometry regenerates from `(seed, columns, rows)`.** Saves must never store
  control points.

## Traps already paid for

**macOS window.** With `GENERATE_INFOPLIST_FILE`, the app needs
`INFOPLIST_KEY_NSPrincipalClass[sdk=macosx*] = NSApplication` or **no window is
ever created**. Also: launch through `open`, never the executable directly — a
binary started straight from a shell gets no window.

**Closing the Mac window quits the app.** App Review rejected 1.0 (Guideline 4)
because a closed window left the app running with no menu item to bring it back.
The Mac scene is a single `Window` (listed in the Window menu, no second window
over the one shared `AppModel`), and `AppDelegate` answers
`applicationShouldTerminateAfterLastWindowClosed` with `true` and saves the
live game in `applicationWillTerminate`. Do not turn it back into a
`WindowGroup` on macOS.

**Coordinate systems.** Board space is y-**down**; `CGContext` is y-**up**. Use
`drawFlipped` for images. A piece path drawn without the flip comes out mirrored
(this shipped a flat-top piece upside down once).

**`@ToolbarContentBuilder` conditionals silently produce nothing** on a compact
width. Branch inside the `ViewBuilder`, not at toolbar-content level.

**`.frame(minWidth:)` is a window constraint.** Applying it on iOS forces the
layout wider than the phone screen and pushes the HUD and toolbar off both edges.
Guard it with `#if os(macOS)`. This bites **sheets** as well as the root window —
`SettingsView` and `OriginalImageSheet` each carried an unguarded minimum long
after the window itself was fixed.

**Dynamic colours must be `nonisolated`.** `Theme` builds its colours from
`UIColor { traits in … }` / `NSColor(name:dynamicProvider:)`. SwiftUI resolves
those providers on its render thread; with main-actor default isolation the
closure traps (`dispatch_assert_queue`) the first time the theme changes. Keep
`Theme` and its helpers `nonisolated`.

**`.toolbar(.hidden)` is per screen.** Every screen draws its own header, so the
system bar is hidden — but the modifier on the root view does not reach pushed
destinations; on iPadOS 27 a floating back button appears. `RootView` applies it
inside the `navigationDestination` closure as well.

**One `.sheet` per view, stored on the model.** Several `.sheet` modifiers on
the root stop presenting after the first dismissal, and a hand-made `Binding`
whose getter reads the model is not observation-tracked. `AppModel.sheet` is
the single source; `showSettings`/`showProfile` are computed over it.

**Sheets are `.presentationSizing(.page)`, on the content.** A content-sized
form sheet whose content adapts to `horizontalSizeClass` (or an adaptive
`LazyVGrid`) resizes the sheet, which changes the size class, which re-lays
out the content — the main thread spins at 100 % and the sheet never appears.
The modifier belongs inside the sheet closure, not on the presenter.

**Bundled fonts have no Cyrillic.** Caprasimo and Figtree cover Latin only;
`Theme` attaches a CoreText cascade list so Russian falls back to SF Rounded
Heavy / SF at the same weight instead of a thin default. Fonts are memoised
because a fresh `CTFont` per call is a new `Font` value every render.

**Tests must inject a temp `SaveStore`**, otherwise they write into the player's
real saved games. `GameSession.init(..., saveStore:)` exists for this.

**Saves decode game by game.** The procedural artwork generators (`Sources/Art/`,
`ImageSource.generated`) were removed before 1.0; a save that still names one
fails to decode. `SaveStore` skips just that entry — decoding the archive as a
whole used to mean one unreadable game erased every save on the device. Keep it
that way whenever an `ImageSource` case or a snapshot field goes away.

**Core Image disappointments.** `CIKMeans` + `CIPalettize` produced unusable mush
and `CIEdges` was too weak to survive a multiply blend. The icon pipeline uses a
hand-rolled k-means quantiser and a thresholded Sobel instead. Do not "simplify"
it back. Never `CIColorPosterize` with a saturation boost — it shreds hue.

**Piece textures crop the source**, they do not draw the whole image under a
clip. Cropping a `CGImage` is free; drawing is not.

**Tray drags on touch are a UIKit pan** (`TrayPan` in `TrayView.swift`), not a
SwiftUI gesture. `LongPressGesture.sequenced(before: DragGesture)` lost every
drag whose finger moved more than 10pt inside 0.16 s — i.e. any normal drag —
which is what "pieces cannot be picked up in landscape" was. The pan subclass
decides itself in the first 10pt (steeper than ~20° off the scroll axis lifts
the piece, otherwise it fails and the tray scrolls) and makes the scroll view's
pan wait for it. Verify both directions with `touch_path` on the simulator;
the tray *looks* unscrolled after a flick because rows repeat every 84pt, so
read `onScrollGeometryChange` rather than trusting a screenshot.

**Per-sample state must not live on the screen's view.** The tray ghost's
position used to be a `@State` on `GameView`; every touch sample re-evaluated
the whole screen, including the 800-cell tray grid, which is what made tray
drags on the iPad stutter. `TrayDragState` is its own `@Observable`, read only
by `TrayGhost`. Same idea for texture re-cuts: `PieceTextureStore.rebuild`
on a live board stages the new textures and swaps them in once, and skips
zoom-out entirely (the old, sharper textures downsample fine) — resetting
`progress` there put the full-screen `LoadingOverlay` over every zoom.

**Grabbing goes by the cell, not only the outline.** `GameSession.piece(at:)`
first tests exact outlines; if that finds nothing movable it takes the topmost
loose piece whose square cell (plus 12 % of a side) contains the point. A
piece with four blanks is mostly holes, and outline-only hit testing made it
nearly impossible to pick up with a finger. Locked pieces never get the slack.

**Overlay cards must fit an iPhone in landscape** (under 400pt tall). The
pause and completion cards sit in `FittedCard`, which scrolls when the card is
taller than the screen, and switch to a denser layout on a compact vertical
size class — before that, "Play again" and "Library" were below the screen.
Check with `--stage completed --landscape` on the smallest iPhone.

**iCloud and Game Center only exist in team-signed builds.** The entitlements
are split: `Config/JigsawPuzzle.entitlements` (sandbox only) signs the Mac
Debug build and `install-mac.sh`, both ad hoc; `JigsawPuzzle-Store.entitlements`
signs the Mac Release build and `JigsawPuzzle-iOS.entitlements` every iOS
build. macOS kills an ad-hoc app that claims iCloud or Game Center, so never
put those keys in the plain file. `CloudRecordMirror.isAvailable` reads the
entitlement at run time (and is false in any stage run, so `--clear-saves`
cannot wipe the family's history on every device); `ProfileView` hides the
friends section when it is false.

**One iCloud key-value store, 1 MB in all, three tenants.** `stats.v1`
(≤ 400 KB), `games.v1` (unfinished games on bundled pictures, lzfse JSON,
≤ 560 KB, oldest dropped first) and `settings.*` (name, preferences and seen achievements as a union;
onboarding stays per device, but `AppModel.greetIfNew` skips it for anyone
with a name, a record or a save, so a reinstall does not greet a returning
player). Shared games merge by
newest `updatedAt`; a game finished or deleted anywhere becomes a dated
tombstone in `SharedGames.gone`, so deleting must go through
`AppModel.delete` / `deleteAllSaves`, never `SaveStore` directly. Settings
take the cloud value at launch and push what only this device has;
`AppSettings.reload` never writes, so a fresh install cannot push its
defaults over the family's name.

**One `GameView` per game.** "Play again" swaps `model.session` but keeps the
`.game` route, so `RootView` gives the view `.id(session.id)`; without it the
old view's `didLoad` skipped loading the new game (stuck at "Cutting… 2 %").

**Apple Pencil Pro haptics need `UICanvasFeedbackGenerator`** on the view the
Pencil touched, plus a location; a plain impact generator never reaches the
Pencil. Tray drags start in the tray's view, so `Feedback.dragBegan(in:)` moves
the generator to wherever a drag begins (on the board's view only, tray drops
were silent).

**Synced stats merge, they never overwrite.** Records are only ever added,
so `StatsArchive.merged` is a union by id; a reset is a timestamp that drops
every older record on every device. `PlayerStats.persist` merges with iCloud
before saving, because a key-value save replaces what another device wrote.
The 1.0 file (a bare `[SolvedRecord]`) still loads.

**Game Center identifiers are forever.** `GameCenter.Board` raw values and
`Achievement.gameCenterID` must match App Store Connect → Game Center, and a
leaderboard or achievement that has shipped can never be deleted or renamed.
`daily_time` is a recurring board (1 day, from 00:00 GMT+5) scored in
seconds, lower first; `points_week` is recurring too (1 week, from Monday
00:00 UTC — `PlayerStats.leaderboardWeekStart` must agree), higher first;
`puzzles_solved`, `daily_streak` and `points_total` are classic, higher
first. Achievement and leaderboard art is `docs/gamecenter/` (made by
`Scripts/make-achievement-badges.swift`, no SF Symbols — their licence
forbids that use); activity and challenge art (3840×2160) is
`docs/gamecenter/activities/`, made by `Scripts/make-game-center-art.swift`.
24 achievements use the full 1,000 Game Center points but 10; `firstGift` and
`allSecrets` are hidden, so they never get partial progress (that would
reveal them).

**Challenges count every score.** The Games app's challenges `daily_race`
(on `daily_time`) and `weekly_points` (on `points_week`) take each score
sent to their board as an attempt. `GameCenter.report(finished:)` therefore
sends those two boards only for the game that just ended — never at launch
or after an iCloud sync — and sends that attempt's own time, not the best.
The activities `daily_puzzle` and `quick_puzzle` arrive through
`GKLocalPlayer.local.register` (iOS/macOS 26 only) and land in
`AppModel.open(_:)`.

**Measured frames go stale across a rotation.** `onGeometryChange` reading
`frame(in: .named("game"))` fires once with the final landscape frame and then
again with a bogus frame from the rotation animation — and never again. The
tray's drop test used that frame and rejected drops on the half of the board
nearest the tray, which is what "pieces cannot be dropped in landscape" really
was (touch tests with `--tray-trailing` never rotate, so they never saw it).
`GameView` now derives the board frame from the same numbers that lay it out.
Rotation also arrives as several sizes; `handleResize` re-fits once the aspect
has flipped and the sizes have settled. Reproduce with `--landscape`.

**Resources are flattened.** `Sources/` is a synchronized folder, so anything
under `Sources/Resources/` lands in the bundle root — `Pictures/sea_X.jpg`
becomes `sea_X.jpg`, which is why `LibraryCatalog.bundled()` and
`Feedback.soundURL` look up with `subdirectory: nil`. Consequences: no two
resources may share a name, and a `.gitkeep`/README inside those folders is
copied too (two of them collide with "multiple commands produce"). The
`Pictures/` folder holds the 170 bundled photographs (credits in
`docs/photo-credits.md`). `Sounds/` holds the effects made by
`Scripts/make-sounds.swift` — CAF, not AAC, because AAC's encoder priming
puts ~50 ms of silence in front of every tap — and the two music loops
(`music-library` for the library; `music-piano` or `music` on the board, per
`AppSettings.boardMusic`), which `RootView`
picks from the navigation path and `Feedback.setMusic` crossfades. See
`docs/app-store.md` §5–6.

**Adding pictures reshuffles the daily puzzle.** `dailyItem(on:)` is
`day % count`, and a solved record counts as a daily only while it still
matches, so a bigger library would break every streak retroactively. 1.2's
28 pictures are `LibraryCatalog.rewardOrder`; days before `newPicturesFrom`
rotate over the other 120. Adding more later needs the same treatment (a
second set and cutoff), never a plain file drop.

**Points are derived, like everything in `PlayerStats`.** `PlayerStats.points`
sums the records (a point a piece, ×1.25 from 150 pieces, ×1.5 from 500; the
first daily of a day ×2 plus 50 per streak day, at most 350), so it syncs and
backfills by itself and a statistics reset relocks the reward pictures. Those
are the 28 in `rewardOrder`, four per threshold in `rewardThresholds`;
`AppModel.isLocked` gates `openSetup`, and today's daily picture is never
locked — it is the same worldwide for the daily leaderboard. The
`points_total` leaderboard must exist in App Store Connect before release.

**Secret pictures open with streaks.** The 22 `secret_` pictures
(`ArtCategory.secret`, order in `LibraryCatalog.secretOrder`) open one per
`PlayerStats.giftsEarned` — every seventh consecutive daily day. They are
never in `dailyPool`, their titles stay hidden in the library and in the
photo credits until opened, and `PhotoCredits.byTitle` must list every
bundled picture (a test checks it).

**Bundled picture titles are manual catalog keys.** `bundledItem(at:)` calls
`String(localized:)` with the file name's title at runtime, so Xcode's string
extraction never sees them — add them to `Localizable.xcstrings` by hand.

**Eleven languages, hand-translated.** `Localizable.xcstrings` carries en, ru,
de, fr, es, it, pt-BR, ja, ko, zh-Hans, th; `knownRegions` in the pbxproj lists
the same set. CJK breaks lines between any two characters, so `PillButton`
pins its label to one line. The bundled fonts have no CJK either; the same
cascade that rescues Cyrillic falls through to the system fonts.

**Playing together: the host keeps the board.** `SharedTable` is on every
device at the table; the one that opened it is the host. Every change to the
board is a `BoardMove` applied through `PuzzleState.apply` — local moves via
`GameSession.perform`, a partner's via `performRemote` — so never change the
board's placement any other way, or a shared game drifts. Guests apply their
own moves at once and send them; the host applies moves in arrival order and
sends the whole `PuzzleState` back (lzfse JSON; an 800-piece board stays
under Game Center's 87 KB, a test checks). A guest `adopt`s that board and
replays its unacknowledged moves on top. Held pieces stream ~20 Hz,
unreliable, numbered by drag so a late sample cannot bring a dropped piece
back; a partner's held group is never "home" (it would lock unsettled) and
nothing snaps to it. Undo is off while shared. Points go by
`SolvedRecord.sharedPieces` (the pieces whose first join was this player's);
a shared game never counts for times, Sprinter or the daily. Bundled pictures
only. Nearby needs `NSBonjourServices` (`Config/Info.plist`, merged into the
generated one) and the Mac's network client/server entitlements. Two
simulators on one Mac find each other: `--stage scattered --host-nearby` on
one, `--stage library --join-nearby --carry` on the other. Game Center
invitations only work in team-signed builds with two Apple Accounts.

## Building against the 27 SDKs

Checked against Apple's release notes for Xcode 27 (Swift 6.4), iOS/iPadOS 27 and
macOS 27 "Golden Gate". The app needs no migration, but these are the facts worth
not rediscovering:

- **Deployment targets stay at iOS 18 / macOS 15.** Nothing here requires raising
  them, and `ARCHS_STANDARD` only drops `x86_64` once `MACOSX_DEPLOYMENT_TARGET`
  is ≥ 27.0 — so the Mac build stays universal.
- **The launch-screen requirement is already met.** Apps built with the 27.0 SDK
  are rejected without `UILaunchScreen`/`UILaunchStoryboardName`;
  `INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphone*] = YES` generates it. Do
  not remove that key.
- **`@State` is a macro now, not a property wrapper.** Three patterns stopped
  compiling: giving a `@State` an initial value *and* assigning it in the view's
  own `init`, composing `@State` with another wrapper or macro, and leaning on
  the synthesized private memberwise `init`. No view here does any of them —
  keep it that way. The App's `@State private var model = AppModel()` gets
  *better*: the macro evaluates the initial value once rather than on every
  re-instantiation.
- **Menu symbol images are hidden by default** in macOS 27 context menus and the
  iPadOS 27 menu bar. The library context menus lose their icons and that is the
  intended new look — they are actions. Only force `.labelStyle(.titleAndIcon)`
  on an item that represents an *object*, never to "bring the icons back".
- **iPadOS 27 resizes windows continuously**, and no longer gates that on the
  declared interface orientations. Every frame of a resize drag reaches
  `BoardView.onGeometryChange`, which is why `BoardInputController.handleResize`
  only re-clamps the offset: re-fitting there would rescale the board mid-drag.
- **iPhone Duo (27.1 SDK) is a phone with an iPad-sized inner display**:
  951 × 669 pt open, regular in both size classes, `userInterfaceIdiom`
  still `.phone`. Two things bit: the status bar's column on the trailing
  edge is carved out of the window *after* the first layout, so a board
  fitted once was left under the tray — `handleResize` now refits a board
  the player has not touched since it was fitted; and the tray chose its
  cell size by idiom, giving 72 pt phone cells — `TrayView.trailingWidth`
  now takes the large cells for any game area at least 500 pt tall. Poses
  (Closed, Book, Open) are switched in Xcode's DeviceHub app; there is no
  `simctl` command for them, and powering a display off with
  `simctl io … screenConfig` crashes the simulator's SpringBoard.
- **iPhone Duo half open** (`DeviceHinge.Status.partiallyOpen`, read with
  `onHingeChange`, iOS 27.1) lays the game out across the fold: the fold runs
  across the middle of the screen's long side, so held like a book the tray
  takes the right page and held like a laptop the bottom one. Once the puzzle
  is done the board's page becomes `PhotoFrame` (the picture framed, no
  header; the screen stays on while charging) and the completion card takes
  the other page in its compact layout. `GameView.foldPage` finds the fold from the
  screen's centre in window coordinates, because the status bar's column
  shifts the window. Neither the iOS 27.1 runtime nor DeviceHub is needed to
  look at it: `--half-open` forces the layout on any simulator. Checked
  against the real hinge on the 27.1 simulator in every pose; `onHingeChange`
  also reports the pose at launch. Two traps from that run: as a laptop the
  top safe area is ~60 pt, and a `.background(Color)` touching it extends to
  the screen edge, so `PhotoFrame` keeps only `Theme.bg` out of the safe area;
  and the 669 pt-wide laptop header squeezed the title to "…", so below
  780 pt (`isTightHeader`, iPad mini upright too) the side actions fold into
  the ⋯ menu and the progress bar goes.
- **Not applicable, but easy to misread as urgent:** the `ImageCreator`,
  `FileDocument`/`ReferenceFileDocument` and On Demand Resources deprecations —
  this app uses none of them. `controlSize` is now reset inside sheets and
  popovers, but the two `controlSize` call sites live in `SetupView`, which is
  pushed, not presented.

**Home screen quick actions** are dynamic `UIApplication.shortcutItems`,
rebuilt by `AppModel.refreshQuickActions` each time the app goes to the
background (so "Continue" names the game just left). SwiftUI has no hook for
them: `PhoneAppDelegate` hands a cold launch's item over from the connection
options, `QuickActionSceneDelegate` a running app's, and `QuickAction.pending`
holds one until `RootView` is up.

## Verifying visually

There is no way to read back a live SwiftUI window — `cacheDisplay` and
`CALayer.render` both return blank. Two working routes:

- **`DebugStageDriver`** (debug builds only) drives the app into a named state at
  launch: `open -n "<app>" --args --stage huge --clear-saves`. Stages: `library`,
  `dark`, `settings`, `profile`, `setup`, `board`, `scattered`, `snapped`, `hint`,
  `completed`, `huge`, `hugeSolved`. `--achievements sprinter,space` makes the
  completion announce those, to look at the reveal without earning them. `--tray-trailing` forces the landscape
  layout on a portrait simulator (there is no `simctl` rotate); add
  `-AppleLanguages "(en)" -onboarding YES -appearance light` to pin the rest.
  On the Mac a stage run sizes the window to 1440×900 pt. Any stage run also
  lives in `StageSandbox`: a scratch data directory and a throwaway defaults
  domain, so `--clear-saves` and the `dark` stage never touch the player's
  real saves or settings, even from a debug build that shares the release
  container.
- **Store screenshots**: `Scripts/store-screenshots.sh [lang]` walks the stages
  on the iPhone 17 Pro Max and iPad Pro 13" simulators and the Mac app into
  `docs/store/<lang>/`, numbered in upload order. The Mac build uses bundle
  ID `…SashasPuzzle.screenshots` so `--clear-saves` never touches the family's
  real container; `SIMULATORS=` (empty) shoots the Mac only.
- **Screenshots**: on macOS capture the window only (find its number via
  `CGWindowListCopyWindowInfo`, then `screencapture -o -l <id>`) — a full-screen
  grab exposes the user's desktop. On iOS use `xcrun simctl io <device> screenshot`.

Never publish a screenshot containing the user's own photos or saved games; the
GitHub repository is public.

## Device installs

iOS builds carry the iCloud and Game Center entitlements, so installing on a
device needs the team (`J656PYWTCP`, Peter Sarapkin — the team that signed
1.0 in the App Store) in Xcode → Settings → Accounts; a free
Apple ID cannot sign those capabilities. The Mac Debug build still runs ad hoc.

Free Apple ID: builds expire after **7 days**, at most 10 App IDs can be created
per 7 days (and they cannot be deleted — renaming the bundle burns them fast),
and the iPad needs **Developer Mode** enabled in Settings → Privacy & Security.
