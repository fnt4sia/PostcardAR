# Pinch pickup

The one gesture in the app: pinch to grab a `SeaSnail*` entity in a loaded model, drag it, let
go. Everything here lives in the "Pinch pickup" section of `PostcardARView.swift`'s `Coordinator`.

## Why Vision, not ARKit

ARKit tracks cards, not hands. Picking anything up needs a second, independent read of the
camera feed: Apple's Vision framework, specifically `DetectHumanHandPoseRequest`, which returns
joint positions (thumb tip, index tip, wrist, and so on) for a hand in an image.

The two run side by side, not one feeding the other: `updatePinchDetection()` reads
`session.currentFrame.capturedImage` — the same buffer ARKit is already tracking cards against —
and hands it to Vision separately.

## Decoupled from the render loop

The render loop runs at ~60 fps; hand-pose inference does not need to, and running it there would
add real cost every frame for no benefit. `updatePinchDetection()` is still called from
`onRenderFrame()`, but self-throttles to `handPoseSampleInterval` (15 Hz) and guards against
overlapping inference with `handPoseTaskInFlight` — a slow sample is skipped over, not queued.

Only `capturedImage`, not the `ARFrame` itself, crosses into the `Task`. Carrying the frame would
reproduce the exact retention problem `docs/tracking.md` describes for `session(_:didUpdate
frame:)` — ARKit throttles the camera once too many frames are held alive at once.

Inference itself runs off the main actor (`perform(on:orientation:)` is not `@MainActor`); the
surrounding `Task { @MainActor in ... }` is there so every mutation after the `await` — moving
the crosshair, calling `attemptGrab` — lands back on the same thread the rest of the coordinator
runs on, with no explicit hop.

## Reading the pinch

Four joints, gated in two separate places with two different strictness levels, not one shared
list: thumb tip and index tip gate the point, but only need *one* of them confident, not both
(`updatePinchDetection()`'s first real `guard`, past the no-hand check); wrist and index knuckle
(`.indexMCP`) additionally gate `ratio`, needing both tips *and* both of themselves (a second
`guard`, further down, after the point is already placed). See "Two guards, not one" and "One
tip is enough for the point" below for why. A missing *joint* and a missing *hand* are handled
differently too — see "Occlusion vs. no hand" — but either way, nothing usable this sample means
whatever it gates isn't updated.

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
`pinchOpenConfirmSamples` *consecutive* open samples (~200 ms) before `releaseHeld()` actually
fires; any other sample resets the streak, so a still-closed hand never fades. This is a
consecutive-sample counter, not a wall-clock window, deliberately — a window would treat the
first sample after a stalled/skipped inference (see "Decoupled from the render loop" above) as
having already been open that whole time.

**Two guards, not one.** `updatePinchDetection()` used to gate all four joints together. That
was a real bug, found the hard way: an earlier version also required `indexPIP` there (for a
point-placement scheme since abandoned — see "The point" below), and once the point stopped
using it, a low-confidence read on that now-irrelevant joint still silently dropped the *entire*
sample — ratio, release, drag, all of it, not just the point. That's specifically why a held
snail could freeze "stuck in the air" on release: opening the hand to let go sometimes reads
`indexPIP` as low-confidence, which killed the sample before the release-ratio logic downstream
ever ran. The general lesson — whatever joints feed a guard should be exactly the joints
something *downstream of that guard* still uses, nothing gated "just in case" — applies beyond
the joint that taught it: `wrist`/`indexMCP` are only ever `ratio`'s denominator, never the
point, so they're now a second, separate `guard` placed *after* the point is computed and the
crosshair moved. A wrist/knuckle confidence dip costs `ratio` for that one sample, never the
point's responsiveness.

That dip turned out not to be the rare case the first version of this section assumed — at
close range (a hand held near the camera to pinch) the wrist sits nearer the frame edge and
reads far less confidently than the fingertips routinely, not occasionally. Gated at
`jointConfidenceMinimum` (the fingertip-precision bar), that meant `ratio` — and with it the
ring and release — could silently stop updating for stretches while the point, needing only the
still-confident fingertips, kept moving: ring stuck full, snail never releasing, looking frozen
while the crosshair visibly wasn't. `handScaleJointConfidenceMinimum` is deliberately looser:
`wrist`/`indexMCP` only measure a coarse hand-size reference here, never a position that needs
to be precise, so they don't need the fingertip bar.

**Occlusion vs. no hand.** `updatePinchDetection()` treats "Vision saw nothing at all" and
"Vision saw a hand but can't read it well this sample" as different events, and only the first
erases state. `hand == nil` is the real loss — `pinchPoint` is cleared (hides the crosshair),
`pinchPointFilter` is reset to a fresh `PinchPointFilter()` (so re-acquiring doesn't smooth in
from a stale position and derivative), and `lastHandSeenTime` is what `handPoseLossTimeout`
counts against for a forced release. A present-but-unreadable hand — neither tip confident this
sample, see "One tip is enough for the point" below — skips the update and holds the last
`pinchPoint` *and* leaves `pinchPointFilter`'s state alone, the same dead-band idiom as the card
pose filter. Clearing `pinchPoint` on a mere confidence dip was tried first and was the other
half of the "stuck in the air" bug: `updateHeldSnail()` needs `pinchPoint` to move the snail, and
only `releaseHeld()` clears `held` — so a held snail would freeze mid-drag on an occluded joint
without ever actually being released.

**One tip is enough for the point — and, now, for `ratio` too.** Requiring *both* `thumbTip` and
`indexTip` confident to place the point at all was itself a smaller version of the same "Two
guards, not one" mistake: mid-pinch, the thumb sits directly on top of the index fingertip, so
`indexTip`'s confidence dropping out is the routine case during exactly the drag this gesture
exists for — and requiring both meant the point froze for a full `handPoseSampleInterval`
(~67 ms) *every time*, stacking up into exactly the "smooth when slow, sluggish when fast" feel:
fast motion blurs a tip's read more often, so the faster the drag, the more of these ~67 ms
freezes it hit. The point only needs *one* confident tip now — the midpoint when both are
readable, that one tip's own position otherwise.

`ratio` was left requiring both confident tips at first, on the reasoning that its distance
calculation genuinely needs both positions and a stand-in would be a real accuracy loss, not
just an unnecessary restriction. That held for `evaluatePinch`'s ratio math but missed the actual
consequence: a fast release motion blurs *both* tips at once more often than it blurs one
(they're close together and moving together), so "both confident" samples got rare during
exactly the motion release depends on — `pinchOpenConfirmSamples` rarely got the consecutive
reads it needed, and a `held` snail kept being dragged (the point still updated fine) without
ever collecting enough open samples to release, reading as "floating" rather than frozen. `ratio`
now computes off `thumbJoint`/`indexJoint` — the *raw* joints, regardless of their own
confidence — once `anchorTip` has already established that at least one tip is genuinely
confident this sample. That's the same trust argument the point relies on, extended to `ratio`:
one confident tip vouching for the sample, not each value individually gated.

**The point.** `handPoseRequest.perform(on:orientation:)` is given an explicit orientation hint
(`CGImagePropertyOrientation(rearCameraFor:)`), so Vision rotates internally and hands back
joint locations already in the *upright* image's coordinate space.

`Joint.location` is `Vision.NormalizedPoint` — the new Swift Vision API's own type, not the
plain `CGPoint` the old ObjC-bridged `VNRecognizedPoint.location` returned. It carries its own
conversion, `toImageCoordinates(_:origin:)`, and `screenPoint(for:)` uses that (`origin:
.upperLeft`) rather than hand-rolling a `1 - y` flip against an assumed convention — a first
version did exactly that, assuming `NormalizedPoint` matched the old API's bottom-left-origin
`CGPoint` convention without ever checking, which is exactly the kind of small, silent,
survives-every-later-fix error that produces a persistent offset no amount of joint- or
weight-tuning downstream can close, because the bug isn't in any of that, it's upstream of it.

Getting an upright-image pixel point is only half the job: turning *that* into a screen point is
hand-rolled aspect-fill math, not `ARFrame.displayTransform(for:viewportSize:)`. That API was
tried first — it's the API-documented tool for exactly this job — but the point it produced
never lined up with where `ARView` actually draws its camera background. `screenPoint(for:)`
instead reproduces `ARView`'s aspect-fill rendering directly: scale the upright image
(`Coordinator.uprightImageSize(of:orientation:)`) up until it covers the viewport, crop the
overflow evenly off both sides, place the point in that scaled/cropped rect. This mirrors the
math a working reference implementation (`posehandtest/PointerMapping.swift`) uses for its own
on-screen hand cursor — though that project is on the *old* Vision API, so only the aspect-fill
math transfers, not the coordinate conversion above it.

It's the true midpoint of `thumbTip` and `indexTip` when both are confident — "between thumb and
index," plainly, no weighting — and the one confident tip's own position when only one is (see
"One tip is enough for the point" above). Two other schemes were tried on the way to the
midpoint (`thumbTip` alone; a weighted average biased toward the thumb) specifically *because*
the midpoint looked wrong on screen — but the midpoint itself was never actually the problem.
Both `thumbTip` and `screenPoint(for:)` were still using the unverified `1 - y` flip at the time,
so *every* point it fed was already off by the same upstream error; averaging two wrong points
just looked like a different kind of wrong. Once `toImageCoordinates` replaced the hand-rolled
flip (previous paragraph) and the per-joint conversion was checked against real device numbers
(view/image sizes and the resulting point, printed via `ARStatus.pinchDebug`, matched a
hand-computed expectation), the midpoint became trustworthy again and moved back to true 50/50.
The lesson generalizes: when a computed point looks wrong, check the thing feeding it before
changing *how it's combined* — averaging, weights, and joint choice can't fix an error in the
conversion underneath them, and chasing the symptom at that layer just produces a
different-looking wrong answer, not a right one.

`ARStatus.pinchDebug` (temporary — delete along with its call site in `updatePinchDetection()`
and the line in `ContentView` once this is closed out) prints `viewportSize`, `uprightImageSize`,
the raw normalized `thumbTip`, and the computed point together, so a future report can be
checked against real numbers instead of guessed at.

**The crosshair.** `setUpCrosshair(in:)` hosts `PinchCrosshair` — an ordinary SwiftUI view — as a
plain `UIHostingController` subview of `arView` itself, moved every sample by
`updateCrosshair(at:progress:)` setting `host.view.center` directly, rather than a SwiftUI
overlay positioned with `.position(point)` above `PostcardARView` (tried first, and how
`docs/app-shell.md` used to describe it). That move alone didn't resolve the reported offset —
the actual bug was upstream, in the point itself (previous paragraph), not in how it was
displayed — but it's still the right way to display it: a subview of `arView` shares its
coordinate space with `arView.ray(through:)` (the drag) by construction, instead of by two
frameworks' layout systems happening to agree.

**Filtering: One Euro, not a fixed EMA.** `updatePinchDetection()` runs the raw point through
`pinchPointFilter` (a `PinchPointFilter`, two `OneEuroFilter`s — one per axis, see their doc
comments for why per-axis) once, at sample time, and writes the result straight to `pinchPoint`
— not inside `evaluatePinch` (see "Two guards, not one"), and read directly by both
`updateCrosshair(at:progress:)` and `updateHeldSnail()`.

A fixed-factor EMA (`pinchPointSmoothing`, a single `previous + (raw - previous) * factor` blend)
was tried first, and is a strict jitter-vs-lag dial with no way to be good at both: a factor
steady enough to kill tremor at rest was also damping a fast-moving hand by the same fixed
amount, adding well over 100 ms of lag while dragging — because the filter has no way to know a
still hand and a moving one apart, and 15 Hz sampling means most of that time is spent on
whichever end of the dial you didn't need this instant.

`OneEuroFilter` (Casiez, Roussel, Vogel 2012) is the same idea as an EMA — `alpha * value + (1 -
alpha) * previous` — except `alpha` isn't fixed: its `cutoff` frequency is `minCutoff + beta *
|filtered derivative|`, so a still point gets the same low cutoff (`pinchMinCutoff`) a fixed EMA
would need for steadiness, and a moving one gets a cutoff that rises with how fast it's actually
moving, cutting lag automatically instead of trading it away everywhere at once. `pinchBeta`
controls how fast that rise happens.

That "still point" case still needed tuning before it actually held steady — `pinchMinCutoff`
came down from the reference default (1.0) to 0.5. A lower `derivativeCutoff` (how much the
*derivative itself* is smoothed before it's allowed to push `cutoff` up) was tried first instead,
on the theory that 15 Hz sampling let raw tremor leak through the derivative estimate and nudge
`cutoff` up on a still hand. It made jitter worse: a lower `derivativeCutoff` is a *laggier*
derivative estimate, not a calmer one, so after any real motion it decays back toward zero
slowly — keeping `cutoff` (and the point's responsiveness) elevated for a stretch *after* the
hand had actually stopped, which reads as jitter persisting rather than settling.
`pinchDerivativeCutoff` is left at the reference default for this reason; `pinchMinCutoff` is
the actual knob for rest-state steadiness.

It's *dt*-aware too (needs a real timestamp — `frame.timestamp`
from ARKit's own clock, captured before the `Task` in `updatePinchDetection()`, not `Date()`),
which the fixed EMA wasn't: a skipped sample (occlusion, `handPoseTaskInFlight` overlap) grew a
fixed EMA's effective lag further, since the same fixed factor applied to a now-larger gap still
only closed the same fraction of it. `OneEuroFilter.filter(_:timestamp:)` computes its own `dt`
from consecutive timestamps and folds it into `alpha` directly, so a longer gap between samples
doesn't quietly retune how much lag the filter itself adds.

A render-loop glide toward each new sample — the same idiom as `hold(_:)` for cards, reapplying
a filter every rendered frame (~60 fps) rather than once per sample — was also tried, separately,
before either of the above. It made things worse, not better, for a different reason: gliding
toward a target that itself only moves at `handPoseSampleInterval` (15 Hz) means the displayed
point never catches up before the next sample moves the target again, so it settles into a
steady lag behind the hand rather than ever converging. Filtering at sample time — fixed EMA or
One Euro, either one — has no such catch-up debt: the displayed point is always exactly one
filtered sample old, same recency as no filtering at all, just less noisy.

`attemptGrab`/`updateHeldSnail` use the same filtered `pinchPoint` as the crosshair — no separate
raw-vs-displayed split — since a light per-sample filter (unlike the render-loop glide above)
isn't enough lag to matter for grab timing.

## Grab, drag, release

**Grab** (`attemptGrab(at:)`) is nearest-by-screen-position among `snails` within
`pinchPickRadius` points of the pinch point — not a `RealityKit` hit test, which needs collision
shapes on every snail and would return whatever entity is topmost in the hierarchy rather than
whichever one is visually closest to the pinch. The chosen snail's distance from the camera is
recorded once, in `held`, and held fixed for the drag.

**Drag** (`updateHeldSnail()`) runs every rendered frame — same idiom as `hold(_:)` for cards —
and re-projects `pinchPoint` into a world-space ray via `arView.ray(through:)`, placing the
snail at the fixed grab depth along that ray. Fixed depth means the snail tracks the screen
point at constant distance, rather than sliding toward or away from the camera.

**Release** (`releaseHeld()`) moves the entity into `fading` rather than deleting it immediately.
`updateFadingSnails()` steps its opacity down by `pinchFadeStep` each frame and removes it at
zero — a plain per-frame loop rather than `AnimationResource`, since the render loop is already
iterating every frame regardless.

**Forced release.** If a pinch is closed and Vision stops confidently seeing a hand for
`handPoseLossTimeout`, the snail releases anyway — a hand that lifts out of frame mid-grab would
otherwise never produce the "opened" sample `evaluatePinch` needs to let go with, and the snail
would stay stuck held forever.

## Finding the snails

```swift
private func collectSnails(in entity: Entity) -> [Entity] {
    var found = entity.name.hasPrefix("SeaSnail") ? [entity] : []
    for child in entity.children {
        found.append(contentsOf: collectSnails(in: child))
    }
    return found
}
```

Walked once per model, right after `fit(_:toCardWidth:named:)` in `loadModels()`, and flattened
into one `snails` array shared across every card — pickup works on whichever snail is nearest the
pinch, regardless of which card's model it came from. Anything not named `SeaSnail*` (the coral,
say) is inert scenery and never enters the array.

## Haptics

`pinchHaptics` is a single `UIImpactFeedbackGenerator(style: .soft)`, `prepare()`-d as the ratio
first crosses `pinchOpenRatio` while open — before the grab is confirmed — to hide the Taptic
Engine's spin-up latency. `impactOccurred()` fires full-strength on grab, `intensity: 0.4` on
release: softer because a release is expected, a grab is the moment that needs to feel confirmed.

## Tuning

All the constants above sit at the top of `PostcardARView.swift`, alongside the pose-smoothing
ones. `pinchCloseRatio` / `pinchOpenRatio` are the ones actually worth tuning per hand — read
them live by temporarily printing `ratio` in `updatePinchDetection()`, or by feeding it into
`PinchCrosshair`'s ring (`updateCrosshair(at:progress:)` already computes `progress` from it).

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
"Two guards, not one" above.

There's no point-weighting knob anymore — see "The point" above for why it was tried and
removed.
