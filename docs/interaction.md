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

**Grab** (`attemptGrab(at:)`) is nearest-by-screen-position among `snails` within
`pinchPickRadius` points of the pinch point — not a `RealityKit` hit test, which needs collision
shapes on every snail and would return whatever entity is topmost in the hierarchy rather than
whichever one is visually closest to the pinch. The chosen snail's distance from the camera is
recorded once, in `held`, and held fixed for the drag.

**Drag** (`updateHeldSnail()`) runs every rendered frame — same idiom as `hold(_:)` for cards —
and re-projects the last known pinch point into a world-space ray via `arView.ray(through:)`,
placing the snail at the fixed grab depth along that ray. Fixed depth means the snail tracks the
screen point at constant distance, rather than sliding toward or away from the camera.

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
them live by temporarily restoring the on-screen ratio readout removed after the last tuning
pass (`status.pinchProgress` already reflects them; the raw ratio itself was `ARStatus.pinchRatio`
before it was pulled as a dev-only aid).
