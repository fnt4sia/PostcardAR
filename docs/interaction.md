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
surrounding `Task { @MainActor in ... }` is there so every mutation after the `await` — writing
`status.pinchPoint`, calling `attemptGrab` — lands back on the same thread the rest of the
coordinator runs on, with no explicit hop.

## Reading the pinch

Four joints, each gated on `jointConfidenceMinimum`: thumb tip, index tip, wrist, index knuckle
(`.indexMCP`). No confident read on any of them for a sample means no hand — the crosshair hides
and, if a snail is currently held, the loss clock (`lastConfidentHandTime`) starts running.

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

**The point.** Vision reports joint locations normalized and bottom-left-origin. ARKit's
`displayTransform(for:viewportSize:)` expects top-left, hence the manual `1 - y` flip before
applying it — and the request is deliberately given no orientation hint, because Vision would
otherwise hand back coordinates already rotated for that orientation, and applying
`displayTransform` on top would rotate them a second time.

## Grab, drag, release

**Grab** (`attemptGrab(at:)`) is gated on `game.phase == .playing` — instructions, countdown,
grace and the result screen all leave the model on camera, and pinching through any of them would
otherwise score. Past that gate it is nearest-by-screen-position among `snails` within
`pinchPickRadius` points of the pinch point — not a `RealityKit` hit test, which needs collision
shapes on every snail and would return whatever entity is topmost in the hierarchy rather than
whichever one is visually closest to the pinch. The chosen snail's distance from the camera is
recorded once, in `held`, and held fixed for the drag.

**Drag** (`updateHeldSnail()`) runs every rendered frame — same idiom as `hold(_:)` for cards —
and re-projects the last known pinch point into a world-space ray via `arView.ray(through:)`,
placing the snail at the fixed grab depth along that ray. Fixed depth means the snail tracks the
screen point at constant distance, rather than sliding toward or away from the camera.

**Release** (`releaseHeld()`) moves the entity into `fading` rather than deleting it immediately.
`updateFadingSnails()` steps its opacity down by `pinchFadeStep` each frame and **hides** it at
zero — a plain per-frame loop rather than `AnimationResource`, since the render loop is already
iterating every frame regardless.

Hidden, not `removeFromParent()`: Play Again needs the same snails back on the same coral, and
keeping them in the tree makes that a transform reset rather than a second load of a model already
in memory. Each one carries the local transform it loaded with, and `restoreSnails()` puts it back
— see "Scoring, and putting the snails back" in [simulation.md](simulation.md).

**Forced release.** If a pinch is closed and Vision stops confidently seeing a hand for
`handPoseLossTimeout`, the snail releases anyway — a hand that lifts out of frame mid-grab would
otherwise never produce the "opened" sample `evaluatePinch` needs to let go with, and the snail
would stay stuck held forever.

**Grabbing is limited to visible models.** `attemptGrab(at:)` skips snails that are not
`isEnabledInHierarchy`, so a card that is neither tracked nor locked cannot have its snails picked
up through the camera image. It also skips snails already marked `removed`, so a fading snail
cannot be re-grabbed on its way out.

**Scoring happens here, not at the release.** A grabbed snail always ends up removed — there is no
putting one back — so the grab is the moment it is committed, and the moment the haptic fires.

## Hand presence also locks the cards

Each sample updates two separate clocks, and the difference between them is the whole reason the
lock works at all:

| Clock | Set when | Window | Effect |
|---|---|---|---|
| `lastConfidentHandTime` | all four pinch joints clear `jointConfidenceMinimum` | `handPoseLossTimeout`, 0.3 s | a held snail force-releases |
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
private func collectSnails(in entity: Entity) -> [Entity] {
    var found = entity.name.hasPrefix("SeaSnail") ? [entity] : []
    for child in entity.children {
        found.append(contentsOf: collectSnails(in: child))
    }
    return found
}
```

Walked once per **simulation** model, right after `fit(_:toCardWidth:named:)` in `loadModels()`,
and flattened into one `snails` array shared across every simulation card — pickup works on
whichever snail is nearest the pinch, regardless of which card's model it came from. Anything not
named `SeaSnail*` (the coral, say) is inert scenery and never enters the array.

A showcase card's model is never walked at all, which is the whole implementation of "no pinch on
a showcase card": `attemptGrab(at:)` has nothing to find on one, with no extra test. See
[simulation.md](simulation.md).

## Haptics

`pinchHaptics` is a single `UIImpactFeedbackGenerator(style: .soft)`, `prepare()`-d as the ratio
first crosses `pinchOpenRatio` while open — before the grab is confirmed — to hide the Taptic
Engine's spin-up latency. `impactOccurred()` fires full-strength on grab, `intensity: 0.4` on
release: softer because a release is expected, a grab is the moment that needs to feel confirmed.

## Tuning

All the constants above sit at the top of `PostcardARView.swift`, alongside the pose-smoothing
ones. `pinchCloseRatio` / `pinchOpenRatio` are the ones actually worth tuning per hand — read
them live by temporarily restoring the on-screen ratio readout removed after the last tuning
pass (`status.pinchProgress` already reflects them; the raw ratio itself was `ARStatus.pinchRatio`
before it was pulled as a dev-only aid).
