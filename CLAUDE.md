# PostcardAR

iOS app that recognises printed cards through the camera and anchors a 3D model on top of each
one.

## Concept

1. Every reference image in the app's AR resource group marks *where* a card is. It no longer says
   *which* card: several printed cards may share one image.
2. ARKit tracks all of them in the camera feed every frame.
3. **A QR printed on the card names the model**, and its payload is that model's name verbatim —
   a card carrying `Showcase_postcard` draws `Showcase_postcard.usdz`. Reference images therefore
   only have to track *well*, not track *distinguishably*, which is the hard half to author. See
   `docs/card-identity.md`.
4. The model stays attached to its card while the card is visible: move or tilt the card and the
   model follows.
5. **The QR payload's prefix decides the card's kind.** `Simulation*` runs a minigame on it;
   anything else is a *showcase* card that only stands its model up to be looked at. See
   `docs/simulation.md`.
6. **Which minigame is decided by the model's contents, not its name** — `CoralPlantPoint*` inside
   it means the planting game, `Drupella*` the removal game. See `docs/simulation.md`.
7. Two gestures, and they never overlap. **Pinch**, on simulation cards only, picks up a grabbable
   entity and drags it — read from the camera by Vision, never from the screen; see
   `docs/interaction.md`. **Tap**, on the screen, opens or closes an annotation panel and does
   nothing else at all. Neither moves, selects or otherwise disturbs a model.
8. A model of either kind may carry `ANNO*` entities, which build explanation labels — billboarded
   panels in the scene — from a `.json` file of the same name as the card. **One panel is open at a
   time, and every panel opens in the same place: centred above the model.** See
   `docs/annotations.md`.

Adding a card is a `.usdz` in `PostcardAR/` and a QR carrying its name — no catalog entry of its
own, and no code change; a second file, `<name>.json`, if it has annotations. Any reference image
in the group will carry it. Nothing in the source names an individual card.

**The naming conventions are the whole content API.** All prefix matches, all case-sensitive:

| Name | Means |
|---|---|
| `Simulation*` (QR payload / `.usdz`) | runs a minigame; anything else is a showcase card |
| `ANNO*` | a point to hang an explanation label on; its panel is built into the scene above the model, closed until its dot is tapped, and only one is ever open |
| `Drupella*` | a grabbable snail; `*_Outline` is its outline mesh |
| `CoralPlantPoint*` | a slot a coral can be planted into — and the marker that a model *is* the planting game |
| `CoralPlate*` | optional; the visible socket for the point of the same number, pulsed while that slot is free |
| `SingleCoral*` | a coral that can be picked up and planted |
| `Seafloor*` (in a model) | this model brings its own ground, so the shared `Seafloor.usdz` is not laid under it |

## Stack

Everything is first-party Apple. No third-party dependencies.

| Piece | Framework |
|---|---|
| App shell, button, presentation | SwiftUI |
| Image detection and tracking | ARKit (`ARWorldTrackingConfiguration`, `detectionImages`) |
| 3D rendering and anchoring | RealityKit (`ARView`, `AnchorEntity(.image)`) |
| Hands drawn in front of models | ARKit people occlusion (`frameSemantics = .personSegmentationWithDepth`) |
| Hand-pose detection for pinch pickup, and the occlusion lock | Vision (`DetectHumanHandPoseRequest`) |
| 3D authoring and animation | Reality Composer Pro (bundled with Xcode) |

`ARWorldTrackingConfiguration` is used rather than plain image tracking because image tracking
has no world origin: a card's pose comes back relative to the current camera view, not the
room, since ARKit runs no visual-inertial odometry under that configuration. Panning the phone
past a stationary card then reads to the smoothing filter as the card moving — visible drift
that only settles once the phone stops. World tracking gives the image anchor a room-fixed
pose, so a still card yields a still target and the dead-band filter works as designed.
`maximumNumberOfTrackedImages` must still be set explicitly to the number of reference images —
it defaults to 0 on this configuration, under which a detected card is posed once and frozen
there, the exact "anchor left where the card used to be" failure image tracking was originally
chosen to avoid. See "The session and its configuration" in `docs/tracking.md`.

## Layout

| Path | Purpose |
|---|---|
| `PostcardAR/ContentView.swift` | Start button, the loading/camera swap, and the run's UI (instructions, countdown, HUD, grace, result) |
| `PostcardAR/ModelLibrary.swift` | Reference images and models, loaded once per launch and reused by every scan. Owns `fit`, `removeCameras`, `removeImportedLighting`, `modelWidths` |
| `PostcardAR/PostcardARView.swift` | `UIViewRepresentable` wrapping `ARView`, plus the `Coordinator` that owns the session, entities, filter, model loading, and card kinds |
| `PostcardAR/QRCardIdentity.swift` | Decoding the QR that names a card's model |
| `PostcardAR/PinchInteraction.swift` | Everything pinch pickup touches — the grabbable pool, both minigames' grab/release rules, hand-pose sampling, haptics |
| `PostcardAR/Annotations.swift` | Explanation labels: finding `ANNO*` entities, reading their JSON, and building the billboarded panels into the scene |
| `PostcardAR/GameSession.swift` | The run's state machine and clocks — phases, score, the run, the 5 s grace. Shared by both minigames |
| `PostcardAR/Minigame.swift` | The two games' settings: run length and every word the player reads. One block per game |
| `PostcardAR/Views/` | The Figma-traced screens — home, loading, instructions, countdown, HUD, result — and `DesignTokens`, which owns every colour and every font token |
| `PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/` | One reference image per card, each with its real-world physical size |
| `PostcardAR/<model name>.usdz` | A model a QR can name — see `docs/models.md` for what makes one usable |
| `PostcardAR/<model name>.json` | Annotation text for that model, if it has any — see `docs/annotations.md` |
| `qr/<model name>.png` | Generated QR carrying that name, to print on the card |
| `PostcardAR/Seafloor.usdz` | Not a card. The shared ground plane laid under every model that does not bring its own — see `docs/models.md` |
| `README.md` | What the project is, how to run it, how to add a card |
| `docs/` | Design notes, one file per area |

Documentation is split by area, and each file owns its topic:

| File | Owns |
|---|---|
| `docs/reference-images.md` | The AR resource group, physical size, what makes an image trackable |
| `docs/card-identity.md` | Which model goes on a card: the QR payload, the binding, and why it outlives the payload |
| `docs/models.md` | `.usdz` naming, scaling to the card, weight budget, imported scene contents, how models are lit |
| `docs/tracking.md` | Session, anchors, entity hierarchy, render loop, the occlusion lock, people occlusion, the light estimate |
| `docs/smoothing.md` | The dead band and glide filter, and its three constants |
| `docs/app-shell.md` | SwiftUI, the `UIViewRepresentable` bridge, the screen flow, type and Dynamic Type |
| `docs/interaction.md` | Pinch pickup: Vision hand-pose sampling, grab/drag/release, tuning |
| `docs/simulation.md` | Card kinds, which minigame a model is, both games' rules, the run's phases and clocks, scoring |
| `docs/annotations.md` | Explanation labels: the `ANNO*`/JSON pairing, where a panel is placed, and why it is a texture rather than a SwiftUI view |
| `docs/troubleshooting.md` | Symptom → cause, starting from the Xcode console |

The Xcode target uses a synchronized folder group, so any file added under `PostcardAR/`
is picked up automatically. There is no `project.pbxproj` file list to maintain.

The camera permission string lives in the build settings as
`INFOPLIST_KEY_NSCameraUsageDescription`, not in a checked-in `Info.plist`.

## Entity hierarchy

Two independent lists, joined by the QR. One `CardAnchor` per reference image — pose and printed
size, added to the scene up front, drawing nothing until ARKit tracks its image. One `Card` per
`.usdz` in the bundle — a pivot, empty until a payload names it. See `docs/card-identity.md`.

```
worldRoot (static)     <- AnchorEntity(world: .zero), added once, never written to
  └── pivot            <- smoothed world pose, and the `isEnabled` that drives visibility/lock
        ├── mask       <- generated quad at the card's own printed size, hiding the artwork
        ├── seafloor   <- shared Seafloor.usdz, sized to the *card*, top surface just above y=0
        └── model      <- the QR-named .usdz, sized by `fit` to `modelWidths`, base at y=0

        All three are siblings, so they are rigidly attached to each other and to the card. The
        floor is never a child of the model: `fit` measures the model's own bounds.

AnchorEntity(.image)   <- ARKit rewrites this transform every frame. Never modify it, never
                          parent anything visible under it — see "Visibility" below.
```

The `Coordinator` keeps two arrays and a binding between them: `anchors` of `CardAnchor` (image
name, printed size, anchor entity — where a card is, never which one), `cards` of `Card` (model
name, kind, pivot, `heldPose` — what a card is, never where), and `bound`, the pair a decoded
payload joins. Structs are copied freely because the entities in them are classes; `heldPose` and
the attachment flags need mutating in place, which is why the per-frame loop indexes
(`cards[index]`) rather than iterating values.

ARKit re-solves each card's pose from scratch every frame, and the raw solution wobbles even
when the card is still. Smoothing that means writing a pose of our own — and the anchor is not
somewhere it can be written.

**Never write to an `AnchorEntity`'s transform.** Not the `.image` one, and not a
`AnchorEntity(world:)` either: *any* `AnchorEntity` has an `AnchoringComponent`, and RealityKit
drives its transform from that anchoring target every frame. Writing to it is silently
overwritten, and the model appears pinned in place rather than following the card. Swapping
`.image` for `world: .zero` to "own" the transform does not work and looks like a freeze.

So the smoothed pose goes on the **pivot**, a plain `Entity` with no anchoring component. Each
rendered frame the coordinator reads the anchor's world transform (the raw card pose), filters
it, and writes the result back as the pivot's *world* transform via
`setTransformMatrix(_:relativeTo: nil)`. RealityKit derives the local transform that achieves
it, so the model is drawn at the smoothed pose even though its parent is still jittering.

Each pivot's pose is also cached in that card's `heldPose` rather than read back off the entity,
because the pivot is a child of the jittering anchor — its world transform drifts on frames we
do not steer it. Every frame therefore writes, including "ignore this movement" frames, which
write the previous pose again.

The anchor's local axes follow the image: x across its width, z down its height, y pointing out
of the card's surface.

## Visibility and the occlusion lock

Each card's `pivot` hangs off one shared, static `worldRoot` anchor rather than off that card's
own image anchor — which is what makes the pose ours to write, but also means RealityKit's "hide
an untracked anchor's children" behaviour never reaches the model. **So visibility has to be
driven by hand.** Pivots are created with `isEnabled = false`, and each rendered frame decides:

```swift
let handInFrame = held != nil
    || Date().timeIntervalSince(lastHandSeenTime) < handPresenceTimeout
let isSimulation = cards[index].kind == .simulation
let named = pinch.qrPayload == cards[index].name
let visible = (tracked && named)
    || (cards[index].pivot.isEnabled && (tracked || (handInFrame && isSimulation)))
```

| Card tracked | QR names this card | Hand in frame | Simulation | Model |
|---|---|---|---|---|
| yes | yes | either | either | drawn, pose updated |
| yes | no, but already showing | either | either | drawn, pose updated |
| yes | no, and not showing | either | either | hidden — a card alone never summons a model |
| no | either | yes, and already showing | yes | **locked** in place, pose frozen |
| no | either | no | either | hidden |
| no | either | either | no | hidden |

Two things are load-bearing and must survive any rewrite:

1. **Only a frame that is both tracked and QR-named can enable a pivot.** The lock latches on
   `pivot.isEnabled`, so it can hold a model but never summon one. The payload must *name the bound
   card*, not merely decode: a binding is never cleared, so a bare "some QR is in shot" test lets
   an unrelated code re-summon the last model bound — see `docs/card-identity.md`. Drop that and every model is drawn at the world origin —
   the phone's position at session start — from the moment its `.usdz` loads, because an unwritten
   pivot sits at the identity transform. All models load at launch, so they pile up there and
   whichever card is near that spot appears to have spawned them.
2. **A hand in frame locks, it does not hide.** A hand across the card is the ordinary reason
   tracking is lost and the exact moment the player is reaching for something; a model that blinks
   out then cannot be interacted with. Locked models stay enabled, so their snails stay grabbable
   — this is the base the minigame builds on, not a cosmetic nicety. It is also what keeps a run
   alive through a covered card: `GameSession` is told `cardPresent: visible`, never
   `cardPresent: tracked`.
3. **The lock is simulation-only.** A showcase card has nothing to reach for, so it hides the
   instant its card is lost. Extending the lock to showcase cards leaves models frozen in mid-air
   after their card has gone, for no benefit.

**Presence is observation-level, and must stay that way.** `lastHandSeenTime` is set from
`HumanHandPoseObservation.confidence` alone (`handPresenceConfidence`, 0.1), before any joint is
looked at, and separately from `lastConfidentHandTime`, which needs all four pinch joints. Reusing
the pinch guard for presence is a bug that has already been made once: a palm laid over a card
crops its own wrist out of frame and hides its knuckles, so the four-joint test rejects precisely
the pose the lock exists for, and the lock never fires. `handPresenceTimeout` (1.0 s) is likewise
longer than `handPoseLossTimeout` (0.3 s): Vision samples at 15 Hz and a dropped sample must not
flicker a model, while a late snail release is barely noticeable.

`heldPose` is left alone whether the card is locked or hidden, so a card that comes back glides on
from where it was rather than snapping. `attemptGrab(at:)` skips snails that are not
`isEnabledInHierarchy`, so hidden cards' snails cannot be grabbed while locked ones can. All of
this is per card: losing one leaves the others alone. See `docs/tracking.md`.

## People occlusion

`configuration.frameSemantics.insert(.personSegmentationWithDepth)`, guarded by
`ARWorldTrackingConfiguration.supportsFrameSemantics(_:)` — the guard is mandatory, an
unsupported semantic **throws**, and it needs an A12 or later. RealityKit applies it with no
further setup: ARKit mattes people out of the camera frame per pixel and compares segmentation
depth against rendered depth, so a hand in front of the coral hides it and a hand behind it does
not. Without it every model is painted over the camera image and reads as a sticker on the lens.

People only — the card, the table, and everything else still get drawn over. Occluding against
arbitrary geometry is `sceneUnderstanding.options.occlusion`, LiDAR-only, and is not used here.

## Lighting

**Fixed, and deliberately deaf to the room.** `configuration.isLightEstimationEnabled = false`, and
two things light the scene in its place:

1. **A key `DirectionalLightComponent`** on a child of `worldRoot`, at RealityKit's own default
   2145.7 lux, pitched 70° down so it also catches the fronts of the models. A child, never the
   anchor itself — an `AnchorEntity`'s transform is RealityKit's to write.
2. **An ambient environment**, built by `Coordinator.studioEnvironment()`: a three-stop vertical
   gradient (`skyZenithColor`/`skyHorizonColor`/`skyGroundColor`) rendered to a 256 × 128 `CGImage`,
   turned into an `EnvironmentResource(equirectangular:)`, and assigned to
   `arView.environment.lighting.resource`. `environmentIntensityExponent` scales it as a power of
   two.

**The key light is load-bearing and must not be removed to "simplify".** The environment is built at
run time out of a generated image and an `EnvironmentResource` initialiser, and every step of that
can fail on a device in a way nothing on screen explains. A directional light is a number in a
component. With it there, a failed environment means harsh one-sided lighting with black shadow
faces — a bug you can see and describe. Without it, it meant a black screen.

`environmentIntensityExponent` moves the ambient fill; `keyLightIntensity` moves the key. Reach for
the second if the *shadow* sides are what is too dark.

**`arView.environment` is read once and written once.** It is a struct behind a get/set pair, so
`arView.environment.lighting.resource = x` is a read-modify-write of background, lighting and reverb
together — two of those in a row and the second writes back whatever the getter gave it for what the
first one set. `background` is the field that matters: lose it and the passthrough camera is
replaced by a flat colour, which reads as the whole app going dark rather than as a lighting bug. It
is set to `.cameraFeed()` explicitly in the same write rather than trusted to survive.

`isLightEstimationEnabled` defaults to **on**, and leaving it there is what made models dark up
close and bright further away: ARKit measures one `ambientIntensity` for the whole camera frame and
RealityKit scales the environment by it, so the estimate reads the *framing* rather than the light
on the card. Leaning in fills the frame with one dark card under the phone's own shadow and the
estimate collapses; pulling back lets the ceiling in and it jumps back. Brightness ended up
tracking how the phone was held. Do not turn it back on without replacing that behaviour.

A gradient rather than a flat colour, because a uniform environment lights every face identically
and the model reads as a flat cut-out. Neutral greys, because the textures are baked and already
carry their own colour. `environmentTexturing` stays `.none`: a real room probe costs per-frame CPU
and only reintroduces the same dependence on where the camera is pointing.

The trade is explicit — models no longer match the room's own light, and in exchange they look the
same in every room and at every distance. Full account in `docs/models.md`; the estimate itself in
`docs/tracking.md`.

## Render loop, not session delegate

Per-frame work runs on `arView.scene.subscribe(to: SceneEvents.Update.self)`.
`ARSessionDelegate` is kept only for `didFailWithError`. Keep the `Cancellable` alive or the
subscription ends.

**Never move per-frame work to `session(_:didUpdate frame:)`.** It delivers one main-thread
callback per camera frame with an `ARFrame` attached, and when the main thread runs behind the
camera those callbacks queue up holding frames:

```
ARSession: The delegate of ARSession is retaining 11 ARFrames. The camera will stop
delivering camera images…
```

That happens without your code storing anything — the queue is upstream of the delegate.

Also do not store an `ARImageAnchor` and re-read `isTracked` from it later. `ARAnchor` is
`NS_SWIFT_SENDABLE` with readonly properties and an `ARAnchorCopying` initialiser: ARKit hands
out a fresh copy per update rather than mutating the one you hold, so a stored anchor's
`isTracked` is frozen `true` forever.

## Pose smoothing

Each frame the raw pose is compared against `heldPose`, and there are only two outcomes:

| Delta from held pose | Treated as | Action |
|---|---|---|
| below `positionDeadBand` / `rotationDeadBand` | tracking noise | hold the previous pose |
| anything larger | real movement | glide by `smoothingFactor` per frame |

The dead band is what kills the idle wobble — it is the important one, because a smoothing
filter chasing a jittering target only jitters more slowly. The glide keeps ordinary handling
from feeling mushy. Three constants, at the top of `PostcardARView.swift`; steadier but laggier
means a larger dead band or a smaller smoothing factor.

There is deliberately no third "snap" regime for large jumps. `smoothingFactor` of 0.15 at 60 fps
closes a 50 cm jump in about half a second, which is fast enough that even a card reappearing
somewhere new just glides there — see "Visibility" above for why `heldPose` survives loss
rather than being cleared.

## Status

`ARStatus` carries exactly two fields, both of which draw player-facing UI:
`annotatedShowcaseVisible` and `handTooClose`. Anything written there is read by `ContentView`, so
do not add a field for diagnosis — there is no debug panel any more. Guard every write with an
inequality check: `@Observable` notifies on every set without comparing, and this runs once a frame.

Diagnostics go to the console through `Coordinator.report(_:)`, which drops repeats because
`didFailWithError` can fire on every frame. That is the only account of a missing `.usdz`, a
malformed `.json`, or a QR naming a model that is not in the bundle, so keep the call sites.

`handTooClose` is not a debug field — it drives player-facing UI. A hand right against the lens
crops out every joint the pinch needs, so nothing responds and nothing says why; while it holds,
`ContentView` blurs the camera with *Move your hand back* during `playing`.

It takes **two** conditions per sample: the hand is measurably close (longest visible finger
segment ≥ 30% of viewport width) *and* that sample failed to produce a pinch. Closeness is measured
rather than inferred, and that is the correction to make if it is ever rewritten: an earlier version
used only "a hand was seen and no pinch could be read", which fires on every unreadable hand —
including one far enough away for its fingertips to drop below `jointConfidenceMinimum`, and one
that has already left frame, since `lastHandSeenTime` keeps reporting a hand for a full
`handPresenceTimeout` afterwards so the occlusion lock can hold. Do not reuse the lock's clocks or
its 0.1 confidence floor to drive UI; they are deliberately generous.

Measure *finger segments*, never the span of the whole hand — the wrist and palm leave the frame
first, so a whole-hand measure collapses exactly when the hand is closest. Hysteresis is
one-directional (5 samples in, instant out), and a live grip is excluded, because the wrist/knuckle
guard fails routinely mid-pinch and would otherwise blur every drag. See `docs/interaction.md`.

## Type and Dynamic Type

Every font is a token in `DesignTokens.Typography`; no screen calls `Font.custom` with a literal
size. That collection is not tidying — it is the fix. **`Font.custom(_:size:)` is not a fixed size**:
it scales with the system text setting, relative to `.body`, whatever size it is handed. Right for
an 18 pt paragraph, wrong for a 164 pt numeral — body grows ~130% at the largest accessibility
setting, which put the countdown digit on course for 380 pt inside a 282 pt card. Each token now
names the text style it resembles, so each size grows on its own curve.

Three pieces, all required:

1. **The tokens**, each pinned with `relativeTo:`.
2. **`accessibleLayout()`**, applied *once* on `ContentView`'s root — never per screen — capping at
   `DesignTokens.maximumDynamicTypeSize`.
3. **`fitsOneLine()` / `fitsBlock()`** wherever the geometry around the text is fixed.

**The cap is `.xxxLarge`, and it was measured by running the screens, not judged.** At
`.accessibility1` the instructions card puts its title above the card's top edge and its Start
button below the bottom one — the content is taller than 439 pt by then, and shrinking inside the
column cannot fix a column that has run out of card. The cards are fixed-size Figma images, so
raising the cap means **giving the cards room first**, not moving the number up.

`fitsBlock()` earns its place on a specific failure: a fixed-height card that cannot fit its column
makes SwiftUI *truncate* the most compressible text in it, which on these panels is the title —
"POINT AT THE CARD AGAIN" came out as "POINT AT THE CARD…". SF Symbols use `@ScaledMetric` rather
than a font token, because `Font.system(size:)` genuinely does not scale. Full account in
`docs/app-shell.md`.

## Card kinds and the run

The QR payload's prefix decides what a card is: `Simulation*` runs a minigame, anything else is a
showcase card. Three things and nothing else turn on that — whether the occlusion lock may hold
the model, whether the model's grabbable entities enter the pool, and whether seeing the card starts
a `GameSession`. Annotations are deliberately not on that list: they key off entities and a JSON
file, on either kind of card.

**Which** minigame is a separate question, answered by the model's contents rather than its name:
`CoralPlantPoint*` inside it means PlantingCoral, `Drupella*` means RemovingDrupella, neither is
reported. That keeps "add a card = drop files, change no code" true and avoids a second naming rule
that would have to agree across the reference image *and* the `.usdz`. The game is recorded per
grabbable piece, not once for the app, because the pool is shared across cards and two cards running
different games can be in frame together.

Both games share `GameSession` unchanged — same phases, same clock, `+1` a piece, and both score at
the moment their gesture actually **succeeds**: a coral when it seats in a plant point, a snail when
it is let go of clear of the coral rather than put back on it. Nothing is scored at the grab, which
is only a piece in hand.

What differs between them is settings, not code, and all of it lives in `Minigame.swift`: the run
length (30 s removal, 45 s planting — carrying a coral to a named slot is the slower gesture) and
every word on the instructions and result panels. `ContentView` reads that off `game.minigame`, so
nothing in the UI knows which game is on. Full account in `docs/simulation.md`.

**Clearing the card ends the run on the spot.** `GameSession` is told the run's `target` in
`begin(_:target:)` — every snail on the card, or the smaller of the corals and plant points — and
`scored()` goes straight to `finished` on reaching it. Achieving the object of the game is the
ending; sitting out the rest of the clock with nothing left to pick up is only a wait. The target is
counted from the model at load time by `PinchInteraction.setup(for:)`, so it stays a property of the
`.usdz` and no number in the source needs to agree with one in Blender.

The run is a plain state machine in `GameSession.swift`, driven once per rendered frame from
`onRenderFrame()` and drawn by `runOverlay` in `ContentView.swift`:
`idle → instructions → countdown → playing → finished`, with `grace` hanging off `countdown` and
`playing`. `instructions`, `countdown` and `playing` need the card in view; `idle` and `finished`
do not, since a player reading a score is not aiming the phone, and `grace` *is* the wait for the
card.

`instructions` needs it for the opposite reason to the other two: not because there is a run to
protect but because there is not one yet, so losing the card there calls `reset()` outright — no
grace, nothing carried over, the panel goes away with the card and the next card seen starts over.
That makes an ordering detail load-bearing in `updateGame(cardPresent:candidate:)`: `cardPresent`
was computed by the card loop before `activeSimulationCard` was claimed, so it reads `false` on the
claiming frame and must be overridden to `true` there, or `begin(_:target:)` and `reset()` alternate
forever. A card only claims the session once `pinch.setup(for:)` answers for it, so a card whose
model is still loading, or which holds nothing to play with, puts no panel up.

Losing the card mid-*run* splits exactly on the lock. Hand in frame: the model stays, the run does
not notice. No hand: the model hides and the run freezes for 3 s — score and clock held, the card
returning inside that window resuming where it left, the window expiring wiping the run so the
next scan starts from zero. The clock **pauses** rather than draining, because losing the card is
not the player's doing.

Score is `+1` per piece, counted where the gesture succeeds — the plant for a coral, the release
for a snail that comes off rather than going back on. A released snail is hidden rather than
deleted, so Play Again can restore every piece to the local transform it loaded with. Full account
in `docs/simulation.md`.

## Pinch pickup

The gesture that drives the minigames, on simulation cards only: pinch to grab a piece and drag
it. Touch is not involved — the only tap in the app opens an annotation. Runs on
Vision (`DetectHumanHandPoseRequest`), read from the same `capturedImage` ARKit is already
tracking cards against, sampled at 15 Hz — independent of and slower than the 60 fps render loop,
and guarded against overlapping inference. Grab is gated on `phase == .playing` and is then
nearest-piece-by-screen-projection within `pinchPickRadius`, not a hit test; a held piece tracks
the pinch point at fixed camera depth. All of that is shared by both games.

Release is where they part, on the held piece's own `Grabbable.game`. A **snail** near its home slot
snaps back and scores nothing, otherwise fades, hides for good and scores. A **coral** near a free plant point on
its own model seats itself there and scores, taking the point's rotation as well as its position,
otherwise glides back to where it started — a coral never fades and is never lost, because a model
ships only so many. A planted coral keeps the `removed` flag from its grab, so it cannot be taken
back off.

**A held piece draws over the hand holding it**, and only while held. People occlusion is right for
the model you reach past and wrong for the one you are carrying — a pinched snail otherwise vanishes
behind your own fingers. `setDrawsInFront(_:on:)` flips `readsDepth` (iOS 18+) on the held entity's
materials and every exit path restores it; leave those restores alone or a piece draws through the
scene forever. Nothing else is exempted, so hands still occlude the reef.

**A coral plants the instant it is over a free slot**, not on release: landing one is the object of
the game, and committing immediately keeps the success path off the least reliable thing Vision does,
which is catching the exact frame a pinch opens. It is gated on `plantArmDistance` — the coral must
be carried somewhere first, or corals authored beside their slots plant themselves on the frame they
are grabbed and can never be moved.

**Nothing in the app draws a plant point**, and it should stay that way. A `CoralPlantPoint*` is
registered exactly as the model ships it — geometry untouched, transform read but never written. The
only thing the app adds is *emphasis*: a paired `CoralPlate*` has its opacity breathed while its slot
is free and held solid when it is the slot a held coral would drop into, so there is no size to get
wrong. Two app-drawn discs were built and removed for exactly that reason — one sized from the corals
covered 96% of the gap between slots and fused ten markers into one blob.

A coral takes its point's rotation, so a point whose transform the exporter baked flat plants corals
upright; author them as empties.

**When AR geometry looks wrong, dump the asset before theorising.** ModelIO loads a `.usdz`
headlessly and prints every prim's name, transform and bounds in a few lines of Swift. Two successive
theories about misplaced markers were both wrong, and one run of that dump settled it.

**A coral's snap target is measured in screen points, not metres**, and that must not be "tidied"
back into a world-space distance. A held piece is dragged at the depth it was grabbed at, so it rides
a sphere around the camera: a coral picked up in front of the structure stays in front of it, and
lining it up with a slot on screen leaves the two centimetres apart in depth. A world-space radius
small enough to mean anything then never fires, which is exactly the bug this replaced.

Full mechanism, including the open/close debounce and the Vision coordinate-space gotcha, in
`docs/interaction.md`.

## Model scale

Anchoring does not scale. A `.usdz` renders at whatever real-world size it was authored at,
regardless of how big its card is. So each model is measured with `visualBounds` at load time and
scaled to a fixed target width in metres, looked up by card name in `modelWidths` (falling back
to `defaultModelWidth`) — see `fit(_:named:)` in `ModelLibrary.swift`. Deliberately not derived from the card's own
printed width: that field is what ARKit tracks against, and coupling model size to it would mean
two differently-sized cards could never carry equally-sized models. This keeps the model's
authored scale irrelevant, and each card's on-screen size is one tunable number.

Nothing is repositioned at load time — a `SingleCoral*` stays exactly where the model puts it, like
a `Drupella*` — so `fit` measures the whole model with no special case, and the arrangement being
sized is the arrangement that ends up on screen.

**The card mask and the shared seafloor are sized from the card instead**, and deliberately so:
covering the printed artwork is their whole job, so `ARReferenceImage.physicalSize` is the only
correct input for both.

The seafloor takes a uniform **`min`** of the two axis ratios — a *contain* fit, so the floor never
spills past the card's edge; the asset is authored to the card's proportions, so it lands 0.26 mm
short on width and exact on depth. Only `Seafloor_Sand*` is measured, since the pebbles scatter past
the sand's edge. **Its `y` is what stops models looking like they fly:** `fit` stands models base-at
y = 0, and `seafloorEmbed` puts the sand's *top* just **above** that plane, so a model is sunk into
the sand rather than balanced on its highest grain. Positive, and roughly the sand's own 4.6 mm of
undulation. The earlier version pushed the floor 3 mm *down* and that is exactly why models hovered.
A model much wider than the card cannot look attached to a card-sized floor, so `modelWidths` has to
stay under about 0.14 for any card using it.
`Coordinator.mask(for:)` generates a quad at that size — plus `cardMaskBleed`, since a reference
image is rarely cropped to the exact millimetre of the print and an exact-size mask leaves a sliver
of card edge showing. It uses `generatePlane(width:depth:)`, **not** `(width:height:)`: the first
builds the plane in XZ, which is the card's own plane, so the mask needs no rotation.

Its colour and material are **sampled from `Showcase_Biorock.usdz`'s `Seafloor_SandMat`**, not
chosen: `#A99F8B` averaged over that bake's non-padding pixels, at its own roughness 0.95 and
metallic 0, so the mask reads as ground and agrees with the models' own sand under room light. It
is lit rather than unlit for exactly that reason — an unlit quad renders at its authored value and
drifts away from the lit geometry beside it. Full account in `docs/models.md`.

## Imported models carry a whole scene

A `.usdz` from Blender contains the lighting rig and the viewport camera, not just the mesh.
RealityKit turns a USD `Camera` prim into a real `PerspectiveCamera` entity, and adding one to
an `ARView` scene hands rendering to it — **the passthrough camera freezes**, with no error and
nothing in the log. `ModelLibrary.removeCameras(from:)` strips them at load time; do not remove that call.

Imported *punctual* lights — sphere, distant, rect — come in as inert entities and are left alone:
a Blender point light in a `.usdz` lights nothing here, and no setting changes that. **The
`DomeLight` is the exception and is not inert.** Since iOS 18 RealityKit imports one as an
`ImageBasedLightComponent`, which *overrides* the scene environment for its whole subtree — so
whatever `arView.environment.lighting` is set to stops reaching that model, silently. Every `.usdz`
here ships one and all of them are near-black (`color_0C0C0C.exr`, `color_191C21.exr`), which is
why the models rendered almost black. `ModelLibrary.removeImportedLighting(from:)` strips them at
load, beside `removeCameras`; do not remove that call either.

**Nothing auto-plays either.** RealityKit imports animation into `Entity.availableAnimations` and
leaves it *stopped*. `Coordinator.play(in:)` starts every clip looping at load, walking the whole
tree — RealityKit hangs the animation library on whichever entity the clip targets, not necessarily
the root. Before blaming that code, check the animation survived export at all:
`usdcat --flatten *.usdc | grep -c timeSamples` returns `0` for every `.usdz` in this project today,
so there is currently nothing for it to play. See `docs/models.md`.

Diagnose an imported asset by walking the loaded entity tree and printing components, rather
than by reading the file size — the shipped coral is 9 MB and froze the camera, while a 52 MB
model did not.

## Loading, and where it happens

**Nothing loads inside the camera screen.** `ModelLibrary` reads the reference images and every
model once per launch, behind `LoadingView`, and `Coordinator.start(in:)` only clones what is
already there. Three things forced that shape, and undoing any of them brings back a hang:

1. `ARReferenceImage.referenceImages(inGroupNamed:)` is synchronous and decodes every card image
   in the group to full-size RGBA. Called from `makeUIView` — which is where it used to be — it
   blocks the presentation of the camera screen. It now runs in a detached task.
2. **Reference images have a resolution ceiling.** ARKit gains nothing above ~1800px on the long
   edge; the two cards once shipped at 5855 × 7605, which is 356 MB of bitmap to decode before the
   camera could appear. See "Resolution" in `docs/reference-images.md`.
3. `ScannerScreen` lives in a `fullScreenCover`, so it and its coordinator are destroyed on
   dismiss. The library is `@State` on `ContentView`, one level *above* the cover, which is what
   makes it survive — put it inside and every scan reloads everything, as it once did.

`model(named:)` hands out `clone(recursive:)` rather than the model itself. A scan mutates what it
is given — corals get planted, snails get hidden, annotation markers lose their geometry — and
`PinchInteraction` reads each piece's *current* transform as the `home` it restores to, so reusing
one tree would record a planted coral's slot as its home. Clones share `MeshResource` and
materials, so nothing is re-uploaded.

## Model weight

Everything runs on the main thread alongside ARKit and SwiftUI, so a heavy `.usdz` stalls the
camera rather than degrading gracefully. Budget **512×512 textures** and **under ~50k
triangles**, and note that the budget is shared: every card's model is loaded at launch and stays
resident, so ten cards means ten models in memory. Models load one after another rather than
concurrently — decoding is main-thread work either way, so overlapping them only makes a
longer stall. File size is not the measure — a `.usdz` is a zip of uncompressed assets, and a
2048² texture costs ~21 MB of GPU memory with mipmaps however well its PNG compressed. See
"Weight" in `docs/models.md` for how to check and reduce an asset.

## Rules

### 1. Do not overengineer

Clean and simple code. No abstraction layers, protocols, managers, or state machines added
"for later". Solve the problem in front of us with the smallest amount of code that reads
clearly. If a feature is not needed for the current step, leave it out.

### 2. Reiterate before acting

Before writing code, check that the approach is one of the best ways to do it — not merely
one that compiles. Verify API availability against the actual SDK rather than from memory.
Prefer the approach that is both simple and correct over the one that is clever. Then build
and confirm it actually works; do not report something as done on the strength of it looking
right.

### 3. Keep docs in sync

`docs/` is split by area, and the table above says which file owns what. When something changes,
update the file that owns it rather than adding a second account of the same thing. A new file is
for a genuinely new area, not for a new version of an existing topic.

Cross-link instead of repeating: a paragraph that belongs in two files belongs in one, with a
link from the other. `README.md` is the entry point — keep the "adding a card" steps there
correct, because that is the part someone follows without reading anything else.
