# PostcardAR

iOS app that recognises a printed postcard through the camera and anchors a 3D model on top of it.

## Concept

1. A reference image of the postcard is hardcoded into the app's asset catalog.
2. ARKit tracks that image in the camera feed every frame.
3. RealityKit renders a `.usdz` model anchored to the tracked image.
4. The model stays attached to the card while the card is visible, and can be rotated by the user.

## Stack

Everything is first-party Apple. No third-party dependencies.

| Piece | Framework |
|---|---|
| App shell, button, presentation | SwiftUI |
| Image detection and tracking | ARKit (`ARImageTrackingConfiguration`) |
| 3D rendering and anchoring | RealityKit (`ARView`, `AnchorEntity(.image)`) |
| 3D authoring and animation | Reality Composer Pro (bundled with Xcode) |

`ARImageTrackingConfiguration` is used rather than world tracking because the postcard is
expected to be held in the hand. It re-tracks the image every frame instead of dropping a
persistent world anchor that would drift.

## Layout

| Path | Purpose |
|---|---|
| `PostcardAR/ContentView.swift` | Start button, presents the AR view full screen |
| `PostcardAR/PostcardARView.swift` | `UIViewRepresentable` wrapping `ARView`; session config, anchor, model loading |
| `PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/` | The reference image and its real-world physical size |
| `PostcardAR/postcard.usdz` | The 3D model (not committed yet — see `docs/setup.md`) |
| `docs/` | Setup and design notes |

The Xcode target uses a synchronized folder group, so any file added under `PostcardAR/`
is picked up automatically. There is no `project.pbxproj` file list to maintain.

The camera permission string lives in the build settings as
`INFOPLIST_KEY_NSCameraUsageDescription`, not in a checked-in `Info.plist`.

## Entity hierarchy

```
AnchorEntity(.image)   <- ARKit rewrites this transform every frame. Never modify it.
  └── model            <- loaded .usdz, animations play here
```

"The model rotates with the postcard" is handled entirely by this parent/child relationship.
`ARImageTrackingConfiguration` re-solves the image's pose each frame and writes it to the
anchor; the model is a child, so it inherits the card's position, rotation, and tilt with no
code of our own.

Because of that, nothing should ever write to the anchor's transform — ARKit owns it and
would overwrite the change on the next frame anyway. If a future feature needs to offset or
spin the model independently of the card, insert an intermediate pivot entity between the
anchor and the model and write to the pivot instead.

The anchor's local axes follow the image: x across its width, z down its height, y pointing
out of the card's surface.

## Model scale

Anchoring does not scale. A `.usdz` renders at whatever real-world size it was authored at,
regardless of how big the card is. So the model is measured with `visualBounds` at load time
and scaled to a fraction of the card's `physicalSize.width` — see `fit(_:toCardWidth:)` and
the `modelWidthRelativeToCard` constant. This keeps the model's authored scale irrelevant.

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

New documentation goes in a new file under `docs/`. If something documented there changes,
update the existing file instead of creating a second one.
