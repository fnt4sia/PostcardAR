# AR tracking

How the app finds cards and keeps models attached to them. The filtering that stops the models
shivering is a separate topic — see [smoothing.md](smoothing.md).

## ARKit vs RealityKit

Two frameworks with a clean split:

- **ARKit** understands the real world. It runs the camera, fuses it with the motion sensors,
  and reports what it found. It draws nothing.
- **RealityKit** draws 3D. It owns the scene graph, meshes, materials, lighting, physics.

`ARView` is RealityKit's view, and it holds an `ARSession` from ARKit. ARKit says where things
are; RealityKit puts pixels there.

## The session and its configuration

```swift
let configuration = ARWorldTrackingConfiguration()
configuration.detectionImages = referenceImages
configuration.maximumNumberOfTrackedImages = referenceImages.count
arView.session.run(configuration)
```

`ARSession` is the running tracking loop. The **configuration** tells it what job to do, and the
class you pick determines the whole behaviour:

| Configuration | Behaviour |
|---|---|
| `ARWorldTrackingConfiguration` | Maps the room via visual-inertial odometry, tracks the device in it. With `detectionImages` set and `maximumNumberOfTrackedImages` above 0, a detected image's anchor keeps updating every frame, room-fixed. |
| `ARImageTrackingConfiguration` | Ignores the room entirely. Locates each image relative to the *camera*, fresh every frame, with no persistent sense of where the device itself is. |

We use world tracking because plain image tracking has no world origin: a card's pose comes
back relative to the current camera view, not the room. Panning the phone past a stationary
card then reads to the smoothing filter as the card moving — the dead band never engages
because the "held" pose keeps sliding with the camera, so the model visibly drags and only
settles once the phone stops. World tracking's device pose (from the room map) factors that
camera motion out, so a still card yields a still target.

`maximumNumberOfTrackedImages` still has to be set explicitly and to the full count: it
defaults to 0 on `ARWorldTrackingConfiguration`, under which a detected image is posed once and
frozen there — the exact "anchor left where the card used to be" failure that ruled out plain
world tracking (without continuous image detection) for cards held in the hand.

`automaticallyConfigureSession = false` on the `ARView` stops it from helpfully replacing our
configuration with its default world-tracking one.

`referenceImages` is the whole AR resource group, read with
`ARReferenceImage.referenceImages(inGroupNamed:bundle:)`. Nothing enumerates individual cards:
the group is the list, and everything else is derived from it.

## Anchors

An **anchor** is ARKit's word for "a tracked position in the real world". Each frame, ARKit
re-solves the pose of everything it is tracking and updates the corresponding anchors.

`ARImageAnchor` is the image-specific kind. Two useful members:

- `transform` — a 4×4 matrix: position and orientation of the image in space.
- `isTracked` — whether it is *currently* visible.

RealityKit's `AnchorEntity` is an `Entity` subclass bound to an AR anchor target:

```swift
AnchorEntity(.image(group: "AR Resources", name: image.name))
```

RealityKit finds the matching `ARImageAnchor` and copies its transform into the entity
continuously. So "the model follows the card" costs no code at all — it is parenting. Rotate the
card, ARKit updates the anchor, the descendants inherit it.

The name is not a constant in the source. It comes from the reference image itself, and the same
string loads the model (`Entity(named: card.name)` finds `<name>.usdz` in the bundle). That
single convention is the entire registration mechanism.

## One branch per card

RealityKit is an **entity-component system**. An `Entity` is an identity with a transform; what
it *is* comes from components attached to it. Entities form a tree, and a child's transform is
relative to its parent — which is what carries a card's pose down to its model:

```
worldRoot (static)     ← one shared anchor, added once, never rewritten
  └── pivot            ← we write a smoothed pose here, only while the card is tracked
        └── model      ← we set scale and position here, once

AnchorEntity(.image)   ← ARKit writes that card's pose here, every frame; read from, never
                          parented to
```

Each card's `pivot` hangs off a single shared `worldRoot` — `AnchorEntity(world: .zero)`, added
once and never written to — rather than off that card's own image anchor. That is what makes the
pose ours to write: an anchor's transform cannot be written to, and a pivot under a *static*
anchor inherits nothing that moves.

The cost of that parenting is that RealityKit no longer hides the model for us. It hides an
anchor's *descendants* while that anchor is untracked, and `pivot` is not one — so a pivot left
enabled draws its model at the world origin (wherever the session started) from the moment the
`.usdz` finishes loading, whether or not its card was ever seen. Visibility is therefore ours to
drive too: pivots are created with `isEnabled = false`, and the render loop turns each one on and
off with its own card's `isAnchored`. See "Tracking loss" below.

There is one `anchor`/`pivot`/model triple per reference image, and they are independent: each
has its own filter state. All of them are built and added to the scene at startup, because an
image anchor is inert until ARKit tracks its image — an off-camera card costs nothing.

The coordinator keeps them in an array of small `Card` structs (name, printed width, anchor,
pivot, `heldPose`). The entities inside are classes, so copying a `Card` still refers to the same
anchor and pivot; only `heldPose` genuinely lives in the struct, which is why the per-frame loop
writes through `cards[index]` rather than through a loop variable.

## Never write to an anchor

The anchor follows the card *exactly*, which includes reproducing ARKit's per-frame noise.
Smoothing that means writing a pose of our own, and the anchor is not somewhere it can be
written: RealityKit rewrites it from the tracked image on the next frame.

The instinct is to stop using an image anchor at all — anchor to the world instead, and apply
the pose by hand:

```swift
let anchor = AnchorEntity(world: .zero)   // ← does not work
```

That fails, and the failure is worth understanding because the code looks completely reasonable.
**Every `AnchorEntity` carries an `AnchoringComponent`**, whatever its target, and RealityKit
drives an anchored entity's transform from that component every frame. `world` is a target like
any other. So the writes are silently overwritten and the model sits pinned at the world origin
instead of following the card — which reads on screen as the model freezing, not as a transform
being ignored.

The rule is not "do not write to image anchors". It is **do not write to anchors**.

So the smoothed pose goes on a plain `Entity` with no anchoring component, inserted between the
anchor and the model. Nothing but our code touches it.

The anchor's local axes follow the image: x across its width, z down its height, y pointing out
of the card's surface.

## Tracking loss, and the occlusion lock

Visibility is not RealityKit's to decide here. It hides an anchor's *descendants* while that
anchor is untracked, and `pivot` is not one — it hangs off the static `worldRoot`. Left enabled,
a pivot renders its model at the identity transform, i.e. the world origin, roughly where the
phone was when the session started. Every model in the group loads at launch, so all of them pile
up there and whichever card you point at near that spot appears to have spawned them. Visibility
is therefore driven by hand, once per rendered frame, from two facts:

```swift
let handInFrame = held != nil
    || Date().timeIntervalSince(lastHandSeenTime) < handPresenceTimeout
let isSimulation = cards[index].kind == .simulation
let visible = tracked || (cards[index].pivot.isEnabled && handInFrame && isSimulation)
```

Read it as three rules, for a **simulation** card:

| Card tracked | Hand in frame | Model |
|---|---|---|
| yes | either | drawn, pose updated |
| no | yes, and it was already showing | **locked** — stays exactly where it was, pose frozen |
| no | no | hidden |

A **showcase** card has only the first and last rows: it hides the instant its card is lost,
whatever the hand is doing. The lock exists so that reaching into the scene does not delete the
thing you are reaching for, and there is nothing to reach for on a showcase card — see
[simulation.md](simulation.md) for what else the two kinds differ in.

`pivot.isEnabled` is both the answer and the lock's own state, which is what keeps the rule to one
line and no extra flags. Only a `tracked` frame can turn it on, so a card that has never been
detected shows nothing whatever the hand does — the lock can hold a model, never summon one.

**Why the lock.** A hand across the card is the ordinary reason ARKit loses it, and it is exactly
the moment the player is reaching for something. Blinking the model out then would make the app
unusable to touch: reach for a snail, the card is covered, the snail vanishes. So a hand in frame
means "this loss is me, hold everything", and the model only clears once the hand is gone too.
Interaction keeps working throughout: a locked model is enabled, so its snails stay grabbable,
which is what makes this the foundation for game mechanics that outlive a moment of tracking.

**"In frame" has to be asked loosely.** `lastHandSeenTime` is set from
`HumanHandPoseObservation.confidence` alone, before any joint is inspected — see "Hand presence
also locks the cards" in [interaction.md](interaction.md). The first version of this lock reused
the pinch guard's four-joint test and consequently never fired: a palm laid over a card crops its
own wrist out of frame and hides its knuckles, which is fine for "is there a hand" and useless for
"where are the fingertips". `handPresenceTimeout` (1.0 s) is also much longer than
`handPoseLossTimeout` — Vision samples at 15 Hz, a dropped sample or two must not blink a model
out, while a slightly late release of a held snail is barely noticeable.

**Seeing it work.** The status panel reports both halves: a green *Hand in frame* line whenever
presence is live, and a yellow *Locked: name* line for any card whose model is on screen without
its card being tracked. A model that disappears when it should have locked is then two different
bugs told apart at a glance — no hand seen (Vision), or hand seen and no lock (this rule).

The status label still reads `Entity.isAnchored` directly, so it says "not detected" while a
locked model is on screen. That disagreement is the lock being visible in the UI, not a bug.

Coming back is not a separate case: `heldPose` is left untouched whether the model was locked or
hidden, so the next tracked pose glides in from it exactly like any other movement (see
[smoothing.md](smoothing.md)). A card that reappears where it was reads as having never moved; a
card that reappears somewhere else glides there over about half a second rather than snapping.

Pinch pickup follows the same visibility rule from the other side: `attemptGrab(at:)` skips any
snail that is not `isEnabledInHierarchy`, so a hidden card's snails cannot be grabbed off screen,
while a locked card's can.

The run running on the card reads the lock the same way. `GameSession` is told
`cardPresent: visible`, not `cardPresent: tracked`, so a card held by the lock keeps its run alive
— anything reading `isAnchored` on its own would end a run the moment a hand covered the card,
which is exactly the case the lock was written to survive. See [simulation.md](simulation.md).

## People occlusion

Without it, RealityKit draws every model over the camera image, so a hand passed in front of the
coral is painted *behind* it — the model looks like a sticker on the lens rather than an object on
the table. One frame semantic fixes the depth ordering:

```swift
if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
    configuration.frameSemantics.insert(.personSegmentationWithDepth)
}
```

ARKit segments people out of each camera frame and, with `…WithDepth`, estimates how far away
each of those pixels is; RealityKit compares that against the depth of what it is drawing and
mattes per pixel. A hand in front of the coral covers it, a hand behind it does not. `ARView`
needs nothing switched on — the semantic alone is the whole integration.

Two constraints worth knowing:

- The check is not advice. Setting an unsupported frame semantic **throws**, so
  `supportsFrameSemantics` is mandatory. It needs an A12 or later; older devices simply keep the
  old always-in-front look.
- It is per *person*, not per object. Hands and arms occlude; the card, the table, and a coffee
  cup do not. Occluding against arbitrary geometry is a different feature (`sceneUnderstanding`
  `.occlusion`, LiDAR only) and is not enabled here.

Segmentation runs on the Neural Engine rather than the main thread, but it is not free — if the
frame rate drops noticeably on an older supported device, this is the first thing to try turning
off.

**It interacts with the lock, and can be mistaken for it failing.** A hand laid flat over the card
is between the camera and the model, so people occlusion correctly mattes the model out — the
screen shows a hand, and nothing behind it. That is the same picture as the lock not working. Tell
them apart by moving the hand *beside* the card rather than over it, with the card still hidden
(a finger over the artwork is enough to lose tracking): the model should stay, frozen, with
*Locked:* in the panel.

All of this is per branch: one card losing tracking only stops writes to its own `pivot`, and the
cards still tracked carry on untouched.

## Render loop, not session delegate

The per-frame work needs something to run on, and the obvious candidate is a trap worth
explaining, because it fails in a way that looks like a memory bug in your own code when it is
not.

**The trap.** `ARSessionDelegate` overloads `session(_:didUpdate:)`: one takes `[ARAnchor]`, one
takes an `ARFrame`. The `ARFrame` version fires once per camera frame, which is exactly what a
per-frame filter seems to want. Use it and you eventually get:

```
ARSession <0x…>: The delegate of ARSession is retaining 11 ARFrames. The camera will stop
delivering camera images if the delegate keeps holding on to too many ARFrames.
```

The message points at your delegate, and the natural reading is "I must be storing a frame
somewhere". You need not be storing anything. Each of those callbacks is delivered to the main
thread *carrying* its frame, and the frame is alive until the callback runs. ARKit produces them
at camera rate; if the main thread — which is also drawing the scene, running SwiftUI, and
decoding a `.usdz` — falls even slightly behind, undelivered callbacks queue up, each one holding
a frame hostage. `ARFrame`s are large (they own the pixel buffer), so ARKit draws a line at a
handful of them and then throttles the camera.

You cannot fix that by being careful with the frame. The queue is upstream of your code.

**The fix.** Take the per-frame work off ARKit's clock and put it on RealityKit's:

```swift
frameSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
    self?.onRenderFrame()
}
```

`SceneEvents.Update` fires once per *rendered* frame and carries no frame data. It cannot back
up, because it is a step inside the render rather than a message delivered to it. If rendering is
slow you get fewer of these — never a backlog. (Keep the returned `Cancellable`; dropping it
unsubscribes.)

There is also nothing left to ask ARKit for. The anchor's world transform *is* the card's raw
pose — RealityKit has already copied it there — so the handler reads its own scene graph:

```swift
let target = card.anchor.transformMatrix(relativeTo: nil)
```

It walks the cards once per rendered frame, showing and filtering the tracked ones and hiding the
rest. That loop is the whole cost of supporting several cards: a few matrix operations
each, on entities RealityKit has already updated.

`ARSessionDelegate` is still implemented, but only for `didFailWithError`.

## A dead end worth not repeating

An earlier version had the anchor callbacks (`session(_:didAdd:)`, `session(_:didUpdate anchors:)`)
remember the last pose and the time it arrived, and had the render loop use that, hiding the
model when no update had arrived recently.

It fails in a way that is easy to misdiagnose: **the model times out and disappears while the
card is sitting in plain view.** The cause is that `ARAnchor` is a snapshot, not a live object:

```objc
NS_SWIFT_SENDABLE
@interface ARAnchor : NSObject <ARAnchorCopying, ...>
@property (nonatomic, readonly) BOOL isTracked;
```

`NS_SWIFT_SENDABLE`, every property `readonly`, and an `ARAnchorCopying` initialiser documented
as being called "any time copy is called". ARKit hands you a fresh copy on each update rather
than mutating the one you hold, so a stored anchor can never change — its `isTracked` is frozen
`true` at the instant it arrived.

That forces the indirect question, "has an update arrived recently?", as a proxy for "is the card
there?" — and those are not the same question. Visibility ends up governed by how often ARKit
chooses to call you, which the API does not guarantee.

Reading the anchor entity's transform on the render loop sidesteps all of it: RealityKit keeps
that entity current, and `isAnchored` answers the visibility question directly.
