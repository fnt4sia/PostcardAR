# Troubleshooting

Start with the status panel, then match the symptom.

## Reading the status panel

The camera screen has a panel in the top corner:

| Line | Meaning |
|---|---|
| **Looking for a card…** / **Detected: `name`, `name`** | Which reference images ARKit is tracking *right now*, from `Entity.isAnchored`. A model can outlive its entry: a card lost while a hand is in frame stays locked on screen — see "Tracking loss, and the occlusion lock" in [tracking.md](tracking.md). |
| **Locked: `name`** (yellow) | That card's model is on screen while ARKit is *not* tracking its card — the occlusion lock is holding it. Absent when nothing is locked. |
| **Hand in frame** / **No hand** | Whether Vision currently sees a hand at all, which is what the lock runs on. Looser than pinching: a hand can be present here and too poorly resolved for `evaluatePinch(ratio:at:)` to read a pinch off it. |
| **Loading models (n/total)…** / **Models loaded (n)** | How many `.usdz` files have finished loading, one per reference image. |
| Red text | An `ARSession` error, or a model that failed to load — named, one line each. |

The panel is hidden while a run is on screen (`countdown`, `playing`, `finished`), where it would
overlap the HUD. It is deliberately kept up for the grace screen. If you need it during a run, put
`finished` and the rest back into `showsStatusPanel` in `ContentView.swift`.

Read them together:

- Never says *Detected* → the reference image is the problem.
- One card detected and another never → that one image, not the app.
- *Detected* but nothing visible on that card → the model. Still loading, missing, or loaded at a
  scale that puts it off-screen or inside the camera.
- Red text → the message names which file or which half failed.

A large `.usdz` can take several seconds, and they load one after another, so the count climbs
rather than jumping. *Models loaded* is what tells you the queue is done.

## Symptoms

### Nothing is ever detected

The image, essentially always. Feature matching is scale-invariant, so the physical size field
cannot cause this — a wrong value means "wrong size or distance", never "nothing detected".

Check Xcode's asset-catalog warnings for that image first; treat them as failures rather than
advice. Then see [reference-images.md](reference-images.md) for what makes a target trackable.

### One card works, another never does

Compare the two images, not the code — every card goes through identical code. The usual causes
are a weak second image, or two cards that share enough artwork (a border, a logo, a background)
that they compete for the same features.

Also confirm the second entry is actually in the group and named as you think: the pairing to its
`.usdz` is by exact name.

### Detected, but no model appears on that card

In order of likelihood:

1. Its `.usdz` is missing or misnamed. A red line names the file it tried to load.
2. Still loading. Watch the count.
3. It loaded and was scaled wrong — see the next two entries.

### Another card's model appears on the card I am scanning, or floats in mid-air

Its `pivot` is enabled while its card is untracked, so the model is being drawn at the identity
transform — the world origin, which is where the phone was when the session started. Every model
in the group loads at launch, so with the flag missing they all pile up there, and whichever card
you point at near that spot appears to have spawned them.

Pivots are created with `isEnabled = false`, and only a *tracked* frame is allowed to enable one.
If that rule was loosened — say the occlusion lock was changed to enable a pivot rather than only
keep one enabled — this is what comes back. See "Tracking loss, and the occlusion lock" in
[tracking.md](tracking.md).

### A model stays on screen after the card is gone

Expected, if the panel shows *Hand in frame*: that is the occlusion lock, holding the model frozen
at its last pose until the hand leaves too. Take the hand out of shot and the model clears within
`handPresenceTimeout` (1.0 s).

If it holds with no hand anywhere, Vision is seeing one — presence is deliberately permissive
(`handPresenceConfidence`, 0.1, on the whole observation), so a face, an arm or a hand-shaped
object can trip it. Raise that constant.

### The model vanishes when I cover the card with my hand — the lock does not fire

Read the panel first; it distinguishes the two causes.

1. **No *Hand in frame*.** Vision is not seeing the hand. Presence is set from
   `HumanHandPoseObservation.confidence` before any joint test — if even that fails, the hand is
   probably too close to the lens, badly lit, or edge-on. Lower `handPresenceConfidence`.
2. ***Hand in frame*, no *Locked:*.** The card's model was not on screen at the moment tracking
   was lost. The lock can only hold a model that was already showing — by design, since that is
   what stops unscanned cards appearing. Detect the card first, then cover it.
3. **Both lines correct, model still not visible.** It is behind your hand: people occlusion is
   doing its job, and your hand is between the camera and the model. Move the hand beside the card
   instead of flat over it, keeping the card obscured, and the model reappears in place.

Historically this failed because presence reused the pinch guard's four-joint test
(`jointConfidenceMinimum` on thumb, index, wrist and knuckle). A palm over a card crops its own
wrist out of frame, so that test rejects exactly the pose the lock exists for. Presence must stay
observation-level.

### My hand is drawn behind the model instead of in front of it

People occlusion is off or unsupported. It is one frame semantic,
`.personSegmentationWithDepth`, set in `start(in:)` behind
`ARWorldTrackingConfiguration.supportsFrameSemantics(_:)` — and the guard is not optional, an
unsupported semantic throws. Devices before the A12 cannot do it at all.

Note it mattes *people* only. A hand occludes the coral; the card, the table and everything else
still get painted over, and no setting here changes that. See "People occlusion" in
[tracking.md](tracking.md).

### The screen fills with texture, or the app looks frozen while the camera still moves

The camera is *inside* the model. A model left unscaled — authored at some arbitrary real-world
size — does exactly this. Normally `fit(_:named:)` prevents it by rescaling to that card's entry
in `modelWidths`; if the measurement failed (a zero-size `targetWidth`, or a model whose
`visualBounds` came back empty), a red line says so and names the card.

### The passthrough camera freezes completely, with no error

A `PerspectiveCamera` entity got into the scene — a `.usdz` exported from Blender carries the
viewport camera, and RealityKit hands rendering over to it. `removeCameras(from:)` strips them at
load, so this means either that call was removed or a camera arrived some other way. See "What
else is in your .usdz" in [models.md](models.md), including how to dump an asset's prim types.

Note that file size proves nothing here: the shipped 9 MB coral froze the camera, a 52 MB model
did not.

### The model shivers when the card is still

Expected without filtering, and the filter is tuned by three constants — see
[smoothing.md](smoothing.md). Before touching them, consider that a weak reference image is the
biggest single cause: fewer feature points mean a worse-conditioned pose fit, so the same pixel
noise moves the answer further.

Being close to the card also exaggerates it — the angular error is unchanged, but it now sweeps
across more pixels.

### The model lags behind the card

`smoothingFactor` closes 15% of the gap per frame. Raise it to track more responsively, lower it
for a calmer model. Do not lower it to fix shiver; that is what the dead bands are for.

### The camera stops delivering images

```
ARSession: The delegate of ARSession is retaining 11 ARFrames. The camera will stop
delivering camera images…
```

Per-frame work ended up in `session(_:didUpdate frame:)`. Those callbacks queue up holding frames
when the main thread runs behind, without your code storing anything. Per-frame work belongs on
`SceneEvents.Update` — see "Render loop, not session delegate" in [tracking.md](tracking.md).

### A model disappears while the card is in plain view

If the code was changed to store an `ARImageAnchor` and re-read `isTracked` from it: `ARAnchor` is
a snapshot. ARKit hands out a fresh copy per update, so a stored one's `isTracked` is frozen
`true` forever, and any timeout built on it fires wrongly. Read `Entity.isAnchored` on the render
loop instead — see the dead end at the end of [tracking.md](tracking.md).

### Everything is slow, or the camera stutters while loading

Model weight. Everything runs on the main thread alongside ARKit and SwiftUI, and every model in
the group loads at launch and stays resident. Budget 512² textures and under ~50k triangles per
model, and remember the budget is shared across cards — see "Weight" in [models.md](models.md).

### Pinching does nothing, or grabs the wrong snail

See [interaction.md](interaction.md) for the whole mechanism. In order of likelihood:

1. `pinchCloseRatio`/`pinchOpenRatio` don't match your hand — these were tuned against one hand
   at one distance from the camera. Widen the gap between them if the pinch feels unreliable.
2. The pinch point landed more than `pinchPickRadius` screen points from every snail. Grabbing
   is nearest-by-screen-position, not a hit test, so it can pick a snail behind the one you meant.
3. Lighting or hand angle — Vision's hand-pose detector needs the hand clearly in frame, same as
   ARKit needs the card clearly in frame.

### A card shows its model but no minigame ever starts

It is a showcase card. Only a reference image whose name starts `Simulation` runs one, and the
`.usdz` has to carry the same prefix or the model will not load at all. Check the name in the
asset catalog — see [simulation.md](simulation.md).

### The result screen never goes away

It does not need the card in view, by design: the player is reading a score rather than aiming the
phone, so losing tracking there does not wipe it. **Play Again** and **Close** are the only ways
out.

### The instructions screen vanished while I was reading it

The card left the frame. `instructions` is card-dependent, and unlike `countdown` and `playing` it
gets no grace period — nothing has started, so there is no score or clock worth holding, and the
panel goes away with the card rather than sitting over a camera pointed at nothing. Point the phone
back at the card and the instructions come up again from the start.

A hand in frame still holds it for up to `handPresenceTimeout` (1 s), because the coordinator
passes `cardPresent: visible` here as everywhere else — the occlusion lock counts. See "The run" in
[simulation.md](simulation.md).

### The instructions screen flickers on and off rapidly

That is the `updateGame(cardPresent:candidate:)` ordering trap, and it means the override on the
claiming frame has been removed. `cardPresent` is computed by the card loop *before*
`activeSimulationCard` is claimed, so it is `false` on the frame `begin(_:target:)` runs; passed through as
`false`, the fresh `instructions` phase is `reset()` back to `idle` on that same frame, and
`begin(_:target:)`/`reset()` alternate forever. The claim branch must force it `true` — `candidate` is only
ever set from a tracked card, so the card is provably there.

### The run restarted from zero when I looked away

The card left the frame with no hand in it either, and stayed away longer than the 3 s grace
period. Inside those 3 s the score and the clock are held and the card coming back resumes exactly
where it left; past them the run is wiped and the next scan is a fresh one.

To keep a run alive while re-aiming, leave a hand in frame — the occlusion lock then holds the
model and the run never enters grace at all. That only works on a simulation card. See "Losing the
card mid-run" in [simulation.md](simulation.md).

### The grace screen appears immediately after tapping Start

The countdown needs the card in view and it is not. Point the phone back at the card; the run
resumes into the countdown with its full 3 s.

### The screen blurred and said "Move your hand back"

Working as intended, and it is telling you why nothing was responding: your hand is close enough to
the lens (roughly under 18 cm) that Vision cannot resolve the joints a pinch needs. Move it further
from the phone.

It appears only during `playing`, only after five consecutive samples agree, and never while a
snail is held or the hand is closed.

### "Move your hand back" appears when my hand is nowhere near the camera

That is the failure mode the current implementation exists to avoid, so it means the closeness
*measurement* has been dropped and the warning is back to inferring proximity from "a hand was seen
and no pinch could be read". That fires on every hand it cannot read for any reason:

- a hand **far away**, whose fingertips fall below `jointConfidenceMinimum`;
- a hand that has **already left frame** — `lastHandSeenTime` keeps reporting one for a full
  `handPresenceTimeout` (1 s) afterwards, on purpose, so the occlusion lock can hold;
- a **phantom** hand at the lock's deliberately-loose `handPresenceConfidence` of 0.1.

The fix is the `tooClose` term in `sample()`: `longestFingerSegment(of:screenPoint:)` against
`handTooCloseSegmentFraction`. See "Why closeness is measured rather than inferred" in
[interaction.md](interaction.md).

### The warning lingers after I move my hand away

The one-directional hysteresis has been made symmetric. `handTooCloseConfirmSamples` gates the way
*in* only; `noteTooClose(false)` clears the flag on the first sample that is not too close,
including the no-hand path. Anything that delays the clear will read as the warning sticking.

### The screen blurs while I am dragging a snail

The `held == nil, !pinchClosed` exclusion in the `tooClose` expression has been dropped. The
wrist/knuckle guard fails routinely during a genuine grip — normal at close range, not a fault — so
without that exclusion the blur lands on the very drag it is complaining about, every time.

### A coral will not snap onto a plant point

Work through these in order:

- **The coral has not been carried far enough yet.** A plant is armed only after the pinch has moved
  `plantArmDistance` (50 points) from where it grabbed — see "Arming" in [simulation.md](simulation.md).
- **Not close enough on screen.** `plantSnapRadius` is 80 *screen points*, measured against where the
  coral appears — not a distance in metres. Raise it to be more forgiving.
- **That slot is already filled**, so it is out of the running.
- **It belongs to another card.** Plant points are matched to their own model by identity, so a coral
  can only be planted on the structure it came from.
- **The run is not `playing`.** A release outside it always returns the coral to where it started.

If it stopped snapping after an edit, check that `plantTarget(for:)` still projects to screen. Reverting
it to a world-space `simd_distance` is the original bug: a held piece is dragged at its grab depth, so
it rides a sphere around the camera and never actually reaches the slot in 3D however well it is aimed.

### A planted coral can still be dragged around

The snap did not happen — the failed-release path is the only one that clears `removed`, so what looks
like "planted but still loose" is really "never planted". See the entry above. A coral that genuinely
snapped keeps `removed` from its grab and `attemptGrab(at:)` skips it.

### Nothing marks where the corals should go

By design: the app draws nothing at a plant point. Put a marker on the `CoralPlantPoint*` in the
model and it renders like any other part of the structure. An app-drawn indicator existed briefly and
was removed — sizing one against an arbitrary model is guesswork the asset can answer directly.

### A planted coral came out at the wrong angle

A coral takes its plant point's rotation. If the exporter baked that transform flat there is no
rotation left in it to read, and corals will sit upright. Author plant points as **empties** with
their rotation intact.

### The held snail or coral is hidden behind my hand

`setDrawsInFront(_:on:)` should be taking it out of the depth test while it is held. Check it is
still called from `attemptGrab(at:)`, and that the material in question is one of the types the
switch handles — an unrecognised type is passed through untouched, so a model using something exotic
would occlude normally. It needs iOS 18 or later for `readsDepth`.

### Something draws through the whole scene, permanently

The reverse of the above: a piece kept its `readsDepth = false` after leaving the hand. Every exit
restores it — `releaseHeld()`, `plant(_:in:)` and `restoreAll()` — so this means a new exit path was
added without one.

### Pinching does nothing during the countdown or after time is up

By design. `attemptGrab(at:)` is gated on `phase == .playing`, because every other phase still
leaves the model on camera and pinching through them would score.

### Play Again starts a run with no snails left

`restoreAll()` did not run. A released snail is *hidden*, not removed from the entity tree,
precisely so a second run can put it back — if `updateFading()` was changed back to
`removeFromParent()`, or the phase-transition test in `PinchInteraction.update()` was loosened,
this is what comes back. Note both halves of that test look at where the phase came *from*:
resuming out of `grace` also lands in `countdown`, and that run's snails must **not** be restored.

### It does not run on the simulator

It cannot. There is no camera feed, `ARWorldTrackingConfiguration.isSupported` is false, and the
app shows a message instead of crashing. AR needs a real device and a physically printed card.

### Xcode shows errors that the build does not

```
Cannot find type 'UIViewRepresentable' in scope
Cannot find 'ARReferenceImage' in scope
```

SourceKit resolving against the macOS SDK. The compiler is the authority — `xcodebuild` builds
clean. Ignore these, or build to confirm.
