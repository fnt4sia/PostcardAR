# PostcardAR

iOS app that recognises printed cards through the camera and anchors a 3D model on top of each
one.

## Concept

1. Every reference image in the app's AR resource group is a card.
2. ARKit tracks all of them in the camera feed every frame.
3. RealityKit renders, on each tracked card, the `.usdz` in the bundle **named after that card's
   reference image** — `postcard` in the group draws `postcard.usdz`.
4. The model stays attached to its card while the card is visible: move or tilt the card and the
   model follows. There are no gestures on the model itself.

Adding a card is two files — an image in the resource group and a `.usdz` of the same name —
and no code change. Nothing in the source names an individual card.

## Stack

Everything is first-party Apple. No third-party dependencies.

| Piece | Framework |
|---|---|
| App shell, button, presentation | SwiftUI |
| Image detection and tracking | ARKit (`ARImageTrackingConfiguration`) |
| 3D rendering and anchoring | RealityKit (`ARView`, `AnchorEntity(.image)`) |
| 3D authoring and animation | Reality Composer Pro (bundled with Xcode) |

`ARImageTrackingConfiguration` is used rather than world tracking because the cards are
expected to be held in the hand. It re-tracks the images every frame instead of dropping a
persistent world anchor that would drift. `maximumNumberOfTrackedImages` is set to the number
of reference images in the group, so every card in view is posed in the same frame.

## Layout

| Path | Purpose |
|---|---|
| `PostcardAR/ContentView.swift` | Start button, and the camera screen's status overlay |
| `PostcardAR/PostcardARView.swift` | `UIViewRepresentable` wrapping `ARView`, plus the `Coordinator` that owns the session, entities, filter, and model loading |
| `PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/` | One reference image per card, each with its real-world physical size |
| `PostcardAR/<image name>.usdz` | The model for the card of that name — see `docs/models.md` for what makes one usable |
| `README.md` | What the project is, how to run it, how to add a card |
| `docs/` | Design notes, one file per area |

Documentation is split by area, and each file owns its topic:

| File | Owns |
|---|---|
| `docs/reference-images.md` | The AR resource group, physical size, what makes an image trackable |
| `docs/models.md` | `.usdz` naming, scaling to the card, weight budget, imported scene contents |
| `docs/tracking.md` | Session, anchors, entity hierarchy, render loop, tracking loss |
| `docs/smoothing.md` | The dead band and glide filter, and its three constants |
| `docs/app-shell.md` | SwiftUI, the `UIViewRepresentable` bridge, the status panel |
| `docs/troubleshooting.md` | Symptom → cause, starting from the status panel |

The Xcode target uses a synchronized folder group, so any file added under `PostcardAR/`
is picked up automatically. There is no `project.pbxproj` file list to maintain.

The camera permission string lives in the build settings as
`INFOPLIST_KEY_NSCameraUsageDescription`, not in a checked-in `Info.plist`.

## Entity hierarchy

One branch per reference image, all added to the scene up front. An image anchor draws nothing
until ARKit tracks its image, so cards that are not on camera cost nothing.

```
AnchorEntity(.image)   <- ARKit rewrites this transform every frame. Never modify it.
  └── pivot            <- we write a smoothed world pose here, every rendered frame
        └── model      <- <image name>.usdz, animations play here
```

The `Coordinator` keeps these in a `cards` array of `Card` structs — name, printed width,
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

## Tracking loss

Not handled in code. RealityKit stops drawing an `.image` anchor's children when that card is
not tracked, which is the wanted behaviour, and `Entity.isAnchored` reports it for the UI
label. On reappearance the card's `heldPose` is nil, so the pose is taken outright instead of
glided to. All of this is per card: losing one leaves the others alone.

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
closes a 50 cm jump in about half a second, and the case that would need instant application —
the card reappearing somewhere new — is already covered by `heldPose` being cleared on tracking
loss, which makes the next pose land outright.

`ARStatus.detectedImages` is rebuilt each frame from `anchor.isAnchored`, so the label and the
models always agree. Guard that write with an inequality check: `@Observable` notifies on every
set without comparing, and this runs once a frame.

## Status

`ARStatus` carries `detectedImages` (names tracked right now), `loadedModels` / `totalImages`,
and `errors`. Errors are a list, not one string: with several models, a missing `.usdz` must not
hide the next one. `report(_:)` drops repeats, because `didFailWithError` can fire on every
frame and the panel is not a log.

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
