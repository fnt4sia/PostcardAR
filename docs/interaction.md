# Pinch pickup

The one gesture in the app: pinch to grab a `Drupella*` entity in a loaded model, drag it, let
go. Everything here lives in `PinchInteraction.swift` — one `PinchInteraction` type that
`PostcardARView.swift`'s `Coordinator` owns and drives; see that file's header for the exact call
surface between the two.

## Why Vision, not ARKit

ARKit tracks cards, not hands. Picking anything up needs a second, independent read of the
camera feed: Apple's Vision framework, specifically `DetectHumanHandPoseRequest`, which returns
joint positions (thumb tip, index tip, wrist, and so on) for a hand in an image.

The two run side by side, not one feeding the other: `sample()` reads
`session.currentFrame.capturedImage` — the same buffer ARKit is already tracking cards against —
and hands it to Vision separately.

## Decoupled from the render loop

The render loop runs at ~60 fps; hand-pose inference does not need to, and running it there would
add real cost every frame for no benefit. `sample()` is still called from
`onRenderFrame()`, but self-throttles to `handPoseSampleInterval` (15 Hz) and guards against
overlapping inference with `handPoseTaskInFlight` — a slow sample is skipped over, not queued.

Only `capturedImage`, not the `ARFrame` itself, crosses into the `Task`. Carrying the frame would
reproduce the exact retention problem `docs/tracking.md` describes for `session(_:didUpdate
frame:)` — ARKit throttles the camera once too many frames are held alive at once.

Inference itself runs off the main actor (`perform(on:orientation:)` is not `@MainActor`); the
surrounding `Task { @MainActor in ... }` is there so every mutation after the `await` — setting
`pinchPoint`, calling `attemptGrab` — lands back on the same thread the rest of `PinchInteraction`
runs on, with no explicit hop.

## Reading the pinch

Four joints, gated in two separate places, not one shared list: thumb tip and index tip gate the
point, needing only *one* of them confident (`sample()`'s first real `guard`, past
the no-hand check — mid-pinch the thumb sits on top of the index fingertip, so requiring both
froze the point every time that tip dropped out); wrist and index knuckle (`.indexMCP`)
additionally gate `ratio`, needing both tips *and* both of themselves, in a second `guard` placed
*after* the point is already computed and drawn. The split matters because whatever joints feed a
guard should be exactly the joints something downstream of it still uses — an earlier version
gated all four together, so a low-confidence read on any one of them (most often the wrist, which
sits nearer the frame edge at close range and reads less confidently than the fingertips do)
silently dropped the ratio, release, and drag along with the point, which is why a held snail
could freeze "stuck in the air": opening the hand to let go often reads one joint as
low-confidence, killing the sample before release logic ever ran. `wrist`/`indexMCP` only measure
a coarse hand-size reference, never a position that needs precision, so they're gated on the
looser `handScaleJointConfidenceMinimum` instead of `jointConfidenceMinimum`.

A present-but-unreadable hand (no confident tip this sample) is not the same event as no hand at
all, and only "no hand" erases state: `hand == nil` clears `pinchPoint`, resets
`pinchPointFilter`, and starts `handPoseLossTimeout`'s clock toward a forced release. A hand
Vision saw but couldn't read well just holds the last `pinchPoint` and leaves the filter alone —
clearing the point on every confidence dip was the other half of the "stuck in the air" bug,
since `updateDrag()` needs it to move the snail and only `releaseHeld()` clears `held`.

**The ratio.** Thumb-to-index distance alone isn't usable — it shrinks as the hand moves away
from the camera even with fingers held apart the same amount. Dividing by wrist-to-knuckle
distance (a proxy for hand size at the current distance) normalizes that away:

```swift
let ratio = Float(thumb.distance(to: index) / wrist.distance(to: knuckle))
```

Small ratio = pinched closed. Large ratio = open. `pinchCloseRatio` / `pinchOpenRatio` are two
separate thresholds, not one, so the debounce in `evaluatePinch(ratio:at:)` has hysteresis: once
closed, the ratio has to climb *past* the open threshold to count as released, so a small tremor
right at one boundary doesn't fire grab/release repeatedly.

That amplitude hysteresis alone isn't enough to call a release, though: a single occluded joint
(the thumb tip, mid-pinch, is exactly the geometry that hides it) can spike the ratio past
`pinchOpenRatio` for one sample without the hand actually opening. Because release is
unrecoverable — the snail is already in `fading`, `pinchOpenStreak` requires
`pinchOpenConfirmSamples` *consecutive* open samples (~133 ms) before `releaseHeld()` actually
fires; any other sample resets the streak, so a still-closed hand never fades. This is a
consecutive-sample counter, not a wall-clock window, deliberately — a window would treat the
first sample after a stalled/skipped inference (see "Decoupled from the render loop" above) as
having already been open that whole time.

`ratio` itself is computed from the *raw* `thumbJoint`/`indexJoint` positions, not the
confidence-filtered ones — it only needs `anchorTip` to have established that at least one tip is
genuinely confident this sample, the same trust argument the point uses. Requiring both tips
individually confident made a fast release (which blurs both tips at once, being close together
and moving together) rarely produce a usable ratio sample, so a released snail kept being dragged
without ever collecting enough open samples to actually let go.

**Forced release.** If a pinch is closed and Vision stops confidently seeing a hand for
`handPoseLossTimeout`, the snail releases anyway — a hand that lifts out of frame mid-grab would
otherwise never produce the "opened" sample `evaluatePinch` needs to let go with.

That timeout counts against `lastPinchEvaluationTime` — the last time `evaluatePinch(ratio:at:)`
actually ran — not "last time a sample saw a hand." An earlier version used the latter and the
timeout never fired: every bail-out that checks it runs on a sample where a hand was *just* seen,
so the elapsed time was always ~0 and the 0.3 s threshold could never be crossed, leaving a held
snail stuck floating indefinitely. `lastPinchEvaluationTime` backs the two bail-outs that have no
other evidence the hand is still there (no hand at all; neither tip readable). The third guard
(wrist/knuckle, above) deliberately skips it: that one fails routinely during a genuine grip, not
rarely, so a timeout keyed to it fired mid-drag on a hand that never left — tried, and it caused
release-then-regrab looping, reading as the snail teleporting. The point staying responsive
through that guard's failures is itself the evidence the hand hasn't gone anywhere.

**The point.** `handPoseRequest.perform(on:orientation:)` is given an explicit orientation hint
(`CGImagePropertyOrientation(rearCameraFor:)`), so Vision rotates internally and hands back
joint locations already in the *upright* image's coordinate space.

`Joint.location` is `Vision.NormalizedPoint` — the new Swift Vision API's own type, not the
plain `CGPoint` the old ObjC-bridged `VNRecognizedPoint.location` returned. It carries its own
conversion, `toImageCoordinates(_:origin:)`, and `screenPoint(for:)` uses that (`origin:
.upperLeft`) rather than hand-rolling a flip against an assumed convention.

Getting an upright-image pixel point is only half the job: turning *that* into a screen point is
hand-rolled aspect-fill math, not `ARFrame.displayTransform(for:viewportSize:)` — that API's
result never lined up with where `ARView` actually draws its camera background. `screenPoint(for:)`
instead reproduces `ARView`'s aspect-fill rendering directly: scale the upright image
(`PinchInteraction.uprightImageSize(of:orientation:)`) up until it covers the viewport, crop the
overflow evenly off both sides, place the point in that scaled/cropped rect. This mirrors the
math a working reference implementation (`posehandtest/PointerMapping.swift`) uses for its own
on-screen hand cursor.

It's the true midpoint of `thumbTip` and `indexTip` when both are confident — "between thumb and
index," plainly, no weighting — and the one confident tip's own position when only one is (see
"Reading the pinch" above).

Nothing draws the pinch point on screen — there is no crosshair. `sample()` keeps sampling
regardless of `game.phase`, because the occlusion lock's hand-presence detection (below) needs to
keep running outside `.playing` too; only the grab/release logic (`attemptGrab(at:)`, gated on
`phase == .playing`) is phase-gated.

**Filtering: One Euro, not a fixed EMA.** `sample()` runs the raw point through
`pinchPointFilter` (a `PinchPointFilter`, two `OneEuroFilter`s — one per axis, see their doc
comments for why per-axis) once, at sample time, and writes the result straight to `pinchPoint`,
read directly by `updateDrag()`.

A fixed-factor EMA (`previous + (raw - previous) * factor`) is a jitter-vs-lag dial with no way to
be good at both: a factor steady enough to kill tremor at rest also damps a fast-moving hand by
the same fixed amount, adding well over 100 ms of lag while dragging, because the filter has no
way to tell a still hand from a moving one.

`OneEuroFilter` (Casiez, Roussel, Vogel 2012) is the same idea — `alpha * value + (1 - alpha) *
previous` — except `alpha` isn't fixed: its `cutoff` frequency is `minCutoff + beta * |filtered
derivative|`, so a still point gets a low cutoff (`pinchMinCutoff`) for steadiness, and a moving
one gets a cutoff that rises with how fast it's actually moving, cutting lag automatically.
`pinchBeta` controls how fast that rise happens; `pinchDerivativeCutoff` smooths the derivative
estimate itself before it's allowed to push `cutoff` up — a *lower* value there makes the
derivative laggier, not calmer, so it stays at the reference default and `pinchMinCutoff` is the
real rest-state knob (see "Tuning" below).

It's also *dt*-aware, using a real timestamp (`frame.timestamp` from ARKit's own clock, captured
before the `Task` in `sample()`, not `Date()`): `OneEuroFilter.filter(_:timestamp:)`
computes `dt` from consecutive timestamps and folds it into `alpha` directly, so a skipped sample
(occlusion, `handPoseTaskInFlight` overlap) doesn't quietly grow the filter's effective lag.

Filtering happens once per sample, not once per rendered frame — a render-loop glide toward each
new sample would mean the tracked point never catches up before the next sample moves the target
again, since the target itself only moves at `handPoseSampleInterval` (15 Hz). Sample-time
filtering has no such catch-up debt: `pinchPoint` is always exactly one filtered sample old.
`attemptGrab`/`updateDrag` both read that same filtered value — no separate raw-vs-used split.

## Grab, drag, release

**Grab** (`attemptGrab(at:)`) is gated on `game.phase == .playing` — instructions, countdown,
grace and the result screen all leave the model on camera, and pinching through any of them would
otherwise score. Past that gate it is nearest-by-screen-position among `snails` within
`pinchPickRadius` points of the pinch point — not a `RealityKit` hit test, which needs collision
shapes on every snail and would return whatever entity is topmost in the hierarchy rather than
whichever one is visually closest to the pinch. The chosen snail's distance from the camera is
recorded once, in `held`, and held fixed for the drag.

**Drag** (`updateDrag()`) runs every rendered frame — same idiom as `hold(_:)` for cards —
and re-projects `pinchPoint` into a world-space ray via `arView.ray(through:)`, placing the
snail at the fixed grab depth along that ray. Fixed depth means the snail tracks the screen
point at constant distance, rather than sliding toward or away from the camera.

**Release** (`releaseHeld()`) first checks whether this is actually a put-back: close enough to the
snail's `home` slot (`pinchSnapRadius`) and the run still `.playing`. If so it glides home via
`Entity.move(to:relativeTo:duration:)`, reverses the score, and clears `removed` — see "Scoring,
and putting the snails back" in [simulation.md](simulation.md) for the full undo path. Otherwise
it moves the entity into `fading` rather than deleting it immediately: `updateFading()` steps
its opacity down by `pinchFadeStep` each frame and **hides** it at zero — a plain per-frame loop
rather than `AnimationResource`, since the render loop is already iterating every frame regardless.

Hidden, not `removeFromParent()`: Play Again needs the same snails back on the same coral, and
keeping them in the tree makes that a transform reset rather than a second load of a model already
in memory. Each one carries the local transform it loaded with, and `restoreAll()` puts it back
— see "Scoring, and putting the snails back" in [simulation.md](simulation.md).

**Forced release.** If a pinch is closed and Vision stops confidently seeing a hand for
`handPoseLossTimeout`, the snail releases anyway — a hand that lifts out of frame mid-grab would
otherwise never produce the "opened" sample `evaluatePinch` needs to let go with, and the snail
would stay stuck held forever.

**Grabbing is limited to visible models.** `attemptGrab(at:)` skips snails that are not
`isEnabledInHierarchy`, so a card that is neither tracked nor locked cannot have its snails picked
up through the camera image. It also skips snails already marked `removed`, so a fading snail
cannot be re-grabbed on its way out.

**Scoring happens at the grab, not the release** — unless the release turns out to be a put-back,
in which case it is reversed. See "Scoring, and putting the snails back" in
[simulation.md](simulation.md).

## Hand presence also locks the cards

Two separate clocks, and the difference between them is the whole reason the lock works at all:

| Clock | Set when | Window | Effect |
|---|---|---|---|
| `lastPinchEvaluationTime` | `evaluatePinch(ratio:at:)` actually runs — both tips and the wrist/knuckle pair all confident | `handPoseLossTimeout`, 0.3 s | a held snail force-releases (see "Forced release" above) |
| `lastHandSeenTime` | Vision returned *any* hand above `handPresenceConfidence` (0.1, whole-observation) | `handPresenceTimeout`, 1.0 s | card models already on screen stay on screen, frozen, though ARKit has lost the card |

**Presence is a looser question than pinching, and asking it the strict way is a bug.** A hand
held flat over a card is a palm filling the frame with the wrist cropped away and the knuckles
hidden behind the fingers. Vision still returns that hand — `HumanHandPoseObservation.confidence`
is respectable — but `.wrist` and `.indexMCP` do not resolve, so the pinch guard rejects the
sample. Gating the lock on that guard meant the lock never fired in the one situation it was
written for: hand over card, card lost, model gone.

So presence reads the observation, not the joints, and is checked *before* the pinch guard rather
than after it. Holding a snail also counts as presence outright (`held != nil`), since a hand that
is mid-grab is unarguably there whatever the current sample managed to resolve.

The lock exists because reaching for a snail is the very thing that covers the card; without it
the model vanishes at the moment of the grab. The full rule, including why a never-detected card
can never be locked into view, is in "Tracking loss, and the occlusion lock" in
[tracking.md](tracking.md).

Hands are also matted out of the render by ARKit's people occlusion, so a hand passed in front of
a snail hides it instead of being painted over — see "People occlusion" in the same file.

## Finding the snails

```swift
private func findDrupella(in entity: Entity) -> [Entity] {
    var found = entity.name.hasPrefix(drupellaPrefix) ? [entity] : []
    for child in entity.children {
        found.append(contentsOf: findDrupella(in: child))
    }
    return found
}
```

`collectSnails(from:)` walks the model with this, then splits the result on `outlineSuffix`
(`"_Outline"`) rather than treating every match as grabbable. The source asset ships each snail's
outline mesh as a flat *sibling* — `Drupella_01` and `Drupella_01_Outline` both sit directly under
`root`, not one nested in the other — so left alone an outline would (a) be independently
grabbable as its own "snail", and (b) stay behind on the coral when the real one is dragged off,
since nothing connects their transforms. `collectSnails(from:)` re-parents each outline under its
matching snail (`setParent(_:preservingWorldTransform:)`, so it doesn't jump on re-parenting) and
only the non-outline matches go into `snails`. Once reparented, an outline moves for free — drag,
snap-back, `restoreAll()` all write the snail's own transform, and RealityKit composes the child's
world transform from it same as any other parent/child pair.

Called once per **simulation** model, right after `fit(_:named:)` in
`PostcardARView.swift`'s `loadModels()` — the coordinator crossing into `PinchInteraction` is the
one place model loading and pinch pickup actually touch. Flattened into one `snails` array shared
across every simulation card — pickup works on whichever snail is nearest the pinch, regardless of
which card's model it came from.

A showcase card's model is never handed to `collectSnails(from:)` at all, which is the whole
implementation of "no pinch on a showcase card": `attemptGrab(at:)` has nothing to find on one,
with no extra test. See [simulation.md](simulation.md).

## Haptics

`pinchHaptics` is a single `UIImpactFeedbackGenerator(style: .soft)`, `prepare()`-d as the ratio
first crosses `pinchOpenRatio` while open — before the grab is confirmed — to hide the Taptic
Engine's spin-up latency. `impactOccurred()` fires full-strength on grab, `intensity: 0.4` on a
release that fades the snail away: softer because that release is expected, a grab is the moment
that needs to feel confirmed.

A snap-back release fires `snapHaptics`, a separate `UINotificationFeedbackGenerator`, instead —
`.notificationOccurred(.success)` rather than a third `.impact` intensity, so "put back, not
collected" reads as its own kind of event rather than one more shade of grab/release.

## Tuning

All the constants above sit at the top of `PinchInteraction.swift`. The card pose-smoothing
constants are a separate set, at the top of `PostcardARView.swift` — see
[smoothing.md](smoothing.md). `pinchCloseRatio` / `pinchOpenRatio` are the ones actually worth
tuning per hand — read them by temporarily printing `ratio` in `sample()`.

`pinchOpenConfirmSamples` trades false-release immunity for release latency — raise it if a
still-pinched snail still fades occasionally, lower it if release starts to feel delayed.

`pinchMinCutoff` (Hz) is the at-rest jitter floor, and the knob for rest-state jitter — lower it
(already brought down from the reference default of 1.0 to 0.5) for a steadier point when still.
`pinchBeta` is how fast the cutoff rises with speed — raise it to cut lag faster once the hand's
moving, at the cost of jitter creeping back in sooner as speed picks up; lower it if fast motion
still feels smoothed-out/behind. `pinchBeta` is left at the reference implementation's published
default; retune it before touching `OneEuroFilter` itself if fast-motion feel is off — see
"Filtering: One Euro, not a fixed EMA" above.

`pinchDerivativeCutoff` is *not* a jitter-at-rest knob, despite looking like one — a lower value
was tried for exactly that and made things worse (see "Filtering" above for why: it's the
derivative's own responsiveness, and a laggy derivative estimate keeps the adaptive cutoff
elevated for longer after real motion, not shorter). Leave it at the reference default; reach for
`pinchMinCutoff` for rest jitter instead.

`handScaleJointConfidenceMinimum` trades `ratio` update reliability for how loosely a `ratio`
sample can be trusted — lower it further if the ring/release still stalls at close range, raise
it if release starts firing off a `wrist`/`indexMCP` read that's really too poor to trust. See
"Reading the pinch" above.

`pinchSnapRadius` is how close a release has to land to the snail's home slot to count as a
put-back instead of a collect — raise it if a light release near the coral still scores, lower it
if a deliberate drag-away snaps back unwanted. `pinchSnapDuration` is just the glide's length.
