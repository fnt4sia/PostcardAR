# Pose smoothing

Why the models hold still, and the three constants that decide how still.

## The symptom

Point the camera at a card lying still on a table and the model does not sit still. It shivers —
a millimetre of drift, a degree of roll, continuously. Move closer and it gets worse, to the
point of looking broken.

## The cause

`ARImageTrackingConfiguration` re-solves each card's pose **from scratch on every frame**. It
keeps no history and does no filtering; frame 200's answer owes nothing to frame 199's. Each
solution is a least-squares fit to feature points found in a noisy, motion-blurred,
rolling-shutter camera image, so each one lands a little differently. That spread is the shiver.

Two things make it worse:

- **A weak reference image.** Fewer, more clustered feature points mean a worse-conditioned fit,
  so the same pixel noise moves the answer further. See
  [reference-images.md](reference-images.md) — no filter beats fixing the image.
- **Being close.** The angular error stays roughly constant, but the model now fills the screen,
  so the same few degrees sweep across far more pixels. Nothing has actually got worse in the
  tracking; you have just zoomed in on the error.

## The fix

Filter the pose before applying it. Each rendered frame, for each tracked card, compare that
card's anchor pose against the pose its model is being **held** at, and pick one of two
behaviours:

```swift
let moved = simd_distance(current.translation, targetPose.translation) > positionDeadBand
let turned = angle(from: current.rotation, to: targetPose.rotation) > rotationDeadBand

var next = current
if moved || turned {
    next = Transform(
        scale: targetPose.scale,
        rotation: simd_slerp(current.rotation, targetPose.rotation, smoothingFactor),
        translation: current.translation
            + (targetPose.translation - current.translation) * smoothingFactor
    )
}

card.heldPose = next
card.pivot.setTransformMatrix(next.matrix, relativeTo: nil)
```

| Regime | Interpretation | Behaviour |
|---|---|---|
| Below both dead bands | Tracking noise. A card is never *actually* moving 1 mm per frame and stopping. | Hold the previous pose. |
| Anything larger | Real handling of the card. | Move `smoothingFactor` of the way there, every frame. |

The filter is per card — `hold(_ card: inout Card)` — because the state it needs is one pose, and
two cards moving independently must not share it. The three constants are shared; the `heldPose`
they act on is not.

## Why it holds rather than returns

The obvious way to write the dead-band case is `return` — do nothing, leave the entity alone.
That is wrong here, and the bug it causes is invisible in the code.

The pivot is a **child of the jittering anchor**. Doing nothing does not mean the model stays
put; it means the model keeps whatever local transform it had, and its world pose continues to
inherit the anchor's jitter. Skipping the write does not suppress the noise, it passes it
straight through.

So the filter keeps its own copy of the pose in `heldPose` and writes **every frame**, including
the frames it decides to ignore — those write the previous pose again. Writing the same world
transform each frame is what actually pins the model in space.

This is also why the pose is cached rather than read back from the entity with
`transformMatrix(relativeTo:)`. Reading it back would return the jittered value the anchor just
imposed, and the filter would be comparing the target against noise instead of against its own
last output.

The write goes to the pivot in **world space**, via `setTransformMatrix(_:relativeTo: nil)`.
RealityKit derives whatever local transform achieves it, so the model is drawn at the filtered
pose even though its parent is still jittering.

## The two parts, and which one matters

The **dead band** is what removes the idle shiver, and it is the important one. Without it,
smoothing alone only slows the wobble down — an exponential filter chasing a jittering target
still jitters, just lazily. Refusing to move at all below a threshold is what makes the model sit
*still*.

The **glide** is an exponential moving average, sometimes called a lerp filter. `0.15` means each
frame closes 15% of the remaining gap, so the model converges in a handful of frames at 60 fps —
fast enough to feel attached, slow enough to average out the noise. Rotation uses `simd_slerp`
rather than a component-wise lerp, because quaternions live on a unit sphere and interpolating
them linearly would take a shortcut through its interior and change the rotation speed mid-way.

## Why there is no third rule for big jumps

An earlier version had a **snap**: past a threshold (8 cm, 30°) the pose was applied instantly,
on the theory that gliding across a large gap at 15% per frame would look like a flight across
the room. Simulating the filter shows the threshold almost never fires and is not needed when it
does:

| Input | Output |
|---|---|
| Card still, ARKit jittering ±1 mm / ±0.5° | 0.0 mm of drift over 300 frames — the dead band absorbs all of it |
| Card slid 10 cm over half a second | Model trails 19 mm at the moment the card stops, settled to 2 mm half a second later |
| A 50 cm jump in one frame | Closed to within 5 mm in 29 frames, about 480 ms |

An 8 cm *per-frame* delta means the card is moving at nearly 5 m/s, which is not handling, it is
throwing. In practice only re-detection produces a jump that large — and re-detection is already
handled, because `heldPose` is cleared on tracking loss and the next pose is taken outright
rather than glided to.

So the third regime was two constants and a branch that bought nothing. If a fly-in ever does
show up on screen, the fix is to restore it, not to lower `smoothingFactor`.

## Tuning

All three constants sit at the top of `PostcardARView.swift` and apply to every card:

| Constant | Default | Raise it to… |
|---|---|---|
| `positionDeadBand` | 2 mm | Kill more positional shiver, at the cost of ignoring small real nudges |
| `rotationDeadBand` | 2° | Kill more rotational shiver, same trade |
| `smoothingFactor` | 0.15 | Track more responsively (**lower** it for a calmer, laggier model) |

Start with the dead bands. They target the specific complaint — "it will not hold still" —
without adding lag to real movement, which is what lowering `smoothingFactor` does.
