# PostcardAR

iOS app that recognises printed cards through the camera and anchors a 3D model on top of each
one.

## Concept

1. Every reference image in the app's AR resource group is a card.
2. ARKit tracks all of them in the camera feed every frame.
3. RealityKit renders, on each tracked card, the `.usdz` in the bundle **named after that card's
   reference image** — `Showcase_postcard` in the group draws `Showcase_postcard.usdz`.
4. The model stays attached to its card while the card is visible: move or tilt the card and the
   model follows.
5. **A card's name prefix decides its kind.** `Simulation*` runs a minigame on it; anything else
   is a *showcase* card that only stands its model up to be looked at. See `docs/simulation.md`.
6. One gesture exists, on simulation cards only: pinch to pick up a `SeaSnail*` entity inside a
   model and drag it — see `docs/interaction.md`. Nothing else on the model responds to touch.

Adding a card is two files — an image in the resource group and a `.usdz` of the same name —
and no code change. Nothing in the source names an individual card.

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
| `PostcardAR/ContentView.swift` | Start button, the camera screen's status overlay, and the run's UI (instructions, countdown, HUD, grace, result) |
| `PostcardAR/PostcardARView.swift` | `UIViewRepresentable` wrapping `ARView`, plus the `Coordinator` that owns the session, entities, filter, model loading, pinch pickup, and card kinds |
| `PostcardAR/GameSession.swift` | The minigame's state machine and clocks — phases, score, the 30 s run, the 5 s grace |
| `PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/` | One reference image per card, each with its real-world physical size |
| `PostcardAR/<image name>.usdz` | The model for the card of that name — see `docs/models.md` for what makes one usable |
| `README.md` | What the project is, how to run it, how to add a card |
| `docs/` | Design notes, one file per area |

Documentation is split by area, and each file owns its topic:

| File | Owns |
|---|---|
| `docs/reference-images.md` | The AR resource group, physical size, what makes an image trackable |
| `docs/models.md` | `.usdz` naming, scaling to the card, weight budget, imported scene contents |
| `docs/tracking.md` | Session, anchors, entity hierarchy, render loop, the occlusion lock, people occlusion |
| `docs/smoothing.md` | The dead band and glide filter, and its three constants |
| `docs/app-shell.md` | SwiftUI, the `UIViewRepresentable` bridge, the status panel |
| `docs/interaction.md` | Pinch pickup: Vision hand-pose sampling, grab/drag/release, tuning |
| `docs/simulation.md` | Card kinds, the run's phases and clocks, losing the card mid-run, scoring |
| `docs/troubleshooting.md` | Symptom → cause, starting from the status panel |

The Xcode target uses a synchronized folder group, so any file added under `PostcardAR/`
is picked up automatically. There is no `project.pbxproj` file list to maintain.

The camera permission string lives in the build settings as
`INFOPLIST_KEY_NSCameraUsageDescription`, not in a checked-in `Info.plist`.

## Entity hierarchy

One branch per reference image, all added to the scene up front. An image anchor draws nothing
until ARKit tracks its image, so cards that are not on camera cost nothing.

```
worldRoot (static)     <- AnchorEntity(world: .zero), added once, never written to
  └── pivot            <- smoothed world pose, and the `isEnabled` that drives visibility/lock
        └── model      <- <image name>.usdz, animations play here

AnchorEntity(.image)   <- ARKit rewrites this transform every frame. Never modify it, never
                          parent anything visible under it — see "Visibility" below.
```

The `Coordinator` keeps these in a `cards` array of `Card` structs — name, kind, printed width,
anchor, pivot, and that card's own `heldPose`. The struct is copied freely because `anchor` and
`pivot` are entities, which are classes; only `heldPose` needs mutating in place, which is why
the per-frame loop indexes (`cards[index]`) rather than iterating values.

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
let visible = tracked || (cards[index].pivot.isEnabled && handInFrame && isSimulation)
```

| Card tracked | Hand in frame | Simulation | Model |
|---|---|---|---|
| yes | either | either | drawn, pose updated |
| no | yes, and already showing | yes | **locked** in place, pose frozen |
| no | no | either | hidden |
| no | either | no | hidden |

Two things are load-bearing and must survive any rewrite:

1. **Only a tracked frame can enable a pivot.** The lock latches on `pivot.isEnabled`, so it can
   hold a model but never summon one. Drop that and every model is drawn at the world origin —
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

The status panel reports `lockedImages` and `handInFrame` for exactly this reason — the lock is
invisible when it works and indistinguishable from a Vision failure when it does not.

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

`ARStatus.detectedImages` is rebuilt each frame from `anchor.isAnchored` — live tracking state,
not what is on screen: a locked model is drawn while its card is listed as not detected, which is
the lock showing through the UI rather than a bug. Guard the write with an inequality check
regardless: `@Observable` notifies on every set
without comparing, and this runs once a frame.

## Status

`ARStatus` carries `detectedImages` (names tracked right now), `lockedImages` (models held on
screen by the occlusion lock), `handInFrame`, `loadedModels` / `totalImages`, and `errors`. Errors
are a list, not one string: with several models, a missing `.usdz` must not hide the next one.
`report(_:)` drops repeats, because `didFailWithError` can fire on every frame and the panel is
not a log.

The lock's two fields are there to make a device-only behaviour observable: a model that vanishes
tells you nothing on its own, while "hand seen, nothing locked" and "no hand seen" are different
bugs. Keep them if the panel is reworked.

## Card kinds and the run

A card's name prefix decides what it is: `Simulation*` runs a minigame, anything else is a
showcase card. Three things and nothing else turn on that — whether the occlusion lock may hold
the model, whether the model's `SeaSnail*` entities enter the grabbable pool, and whether seeing
the card starts a `GameSession`.

The run is a plain state machine in `GameSession.swift`, driven once per rendered frame from
`onRenderFrame()` and drawn by `runOverlay` in `ContentView.swift`:
`idle → instructions → countdown → playing → finished`, with `grace` hanging off `countdown` and
`playing`. Only those two need the card in view; on the other four the player is reading the phone
rather than aiming it.

Losing the card mid-run splits exactly on the lock. Hand in frame: the model stays, the run does
not notice. No hand: the model hides and the run freezes for 5 s — score and clock held, the card
returning inside that window resuming where it left, the window expiring wiping the run so the
next scan starts from zero. The clock **pauses** rather than draining, because losing the card is
not the player's doing.

Score is `+1` per snail, counted at the grab rather than the release: a grabbed snail always ends
up removed, so the grab is where it is committed. That is also why a released snail is hidden and
not deleted — Play Again restores every snail to the local transform it loaded with. Full account
in `docs/simulation.md`.

## Pinch pickup

The one gesture, on simulation cards only: pinch to grab a `SeaSnail*` entity and drag it. Runs on
Vision
(`DetectHumanHandPoseRequest`), read from the same `capturedImage` ARKit is already tracking
cards against, sampled at 15 Hz — independent of and slower than the 60 fps render loop, and
guarded against overlapping inference. Grab is gated on `phase == .playing` and is then
nearest-snail-by-screen-projection within `pinchPickRadius`, not a hit test; a held snail tracks
the pinch point at fixed camera depth; release fades it out and hides it. Full mechanism, including the open/close debounce and the Vision
coordinate-space gotcha, in `docs/interaction.md`.

## Model scale

Anchoring does not scale. A `.usdz` renders at whatever real-world size it was authored at,
regardless of how big its card is. So each model is measured with `visualBounds` at load time
and scaled to a fraction of **its own card's** `physicalSize.width` — see
`fit(_:toCardWidth:named:)` and the `modelWidthRelativeToCard` constant. This keeps the model's
authored scale irrelevant, and lets cards of different printed sizes each size their own model.

## Imported models carry a whole scene

A `.usdz` from Blender contains the lighting rig and the viewport camera, not just the mesh.
RealityKit turns a USD `Camera` prim into a real `PerspectiveCamera` entity, and adding one to
an `ARView` scene hands rendering to it — **the passthrough camera freezes**, with no error and
nothing in the log. `removeCameras(from:)` strips them at load time; do not remove that call.

Imported lights come in as inert entities and are left alone.

Diagnose an imported asset by walking the loaded entity tree and printing components, rather
than by reading the file size — the shipped coral is 9 MB and froze the camera, while a 52 MB
model did not.

## Model weight

Everything runs on the main thread alongside ARKit and SwiftUI, so a heavy `.usdz` stalls the
camera rather than degrading gracefully. Budget **512×512 textures** and **under ~50k
triangles**, and note that the budget is now shared: every card's model is loaded at launch and
stays resident, so ten cards means ten models in memory. Models load one after another rather
than concurrently — decoding is main-thread work either way, so overlapping them only makes a
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
