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
once and never written to — rather than off that card's own image anchor. This is what keeps a
card's model on screen while its anchor goes untracked: RealityKit hides an anchor's *descendants*
whenever that anchor is untracked, and `pivot` is no longer one. See "Tracking loss" below.

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

## Tracking loss

The render loop simply stops updating a card's `pivot` while its anchor is untracked — no
frame writes it, so it holds its last pose. Because `pivot` is parented to the shared
`worldRoot` rather than to the card's own image anchor, it stays in the visible tree the whole
time: nothing hides it, so the model sits exactly where it was, occluded or not.

This is deliberately not the same question as "is the label allowed to say detected". The status
label is still driven straight off `Entity.isAnchored`, so it correctly says "not detected"
while the model keeps holding its place — the two are allowed to disagree on purpose. See
"Status" in the project root `CLAUDE.md`.

Coming back is not a separate case: `heldPose` is left untouched by tracking loss, so the next
tracked pose glides in from it exactly like any other movement (see
[smoothing.md](smoothing.md)). A card that reappears where it was reads as having never moved; a
card that reappears somewhere else glides there over about half a second rather than snapping.

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

It walks the cards once per rendered frame, filtering the tracked ones and clearing the held pose
of the rest. That loop is the whole cost of supporting several cards: a few matrix operations
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
