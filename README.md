# PostcardAR

An iOS app that recognises printed cards through the camera and stands a 3D model on each one.
Hold a card up, move it, tilt it — its model stays attached.

Cards come in two kinds, decided by the front of the card's name:

- **Showcase** — the model is there to be looked at. Nothing to do.
- **Simulation** — a minigame runs on it. Drupella snails are eating the coral; pinch them off,
  as many as you can in 30 seconds.

Everything is first-party Apple: SwiftUI for the shell, ARKit for tracking, RealityKit for
rendering, Vision for the pinch gesture. No third-party dependencies, no package manager, four
Swift files.

## Requirements

- **Xcode 26** or later.
- **A real iPhone or iPad.** The simulator has no camera feed and world tracking reports itself
  unsupported there; the app shows a message rather than crashing.
- **A physically printed card.** Showing a target on another screen works but tracks noticeably
  worse because of glare and moiré.

## Run it

1. Open `PostcardAR.xcodeproj`.
2. Select your device, set a signing team if Xcode asks, and run.
3. Tap **Start Scanning** and point the camera at the printed card.

From the command line:

```sh
xcodebuild -project PostcardAR.xcodeproj -scheme PostcardAR -sdk iphoneos build
```

(If that complains that it requires Xcode, your command line tools are selected instead:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.)

## Adding a card

**The name is the link**, and it carries the card's kind too. A reference image called
`Showcase_postcard` shows `Showcase_postcard.usdz`; a name starting `Simulation` runs the minigame
on that card. Nothing in the code names a card, so adding one is two files and no code change.

```
PostcardAR/
  Assets.xcassets/AR Resources.arresourcegroup/
    Simulation_coral_with_drupella.arreferenceimage   ← the image ARKit looks for
    Showcase_postcard.arreferenceimage
  Simulation_coral_with_drupella.usdz                 ← what appears on it
  Showcase_postcard.usdz
```

1. **Print the card**, and photograph it flat on, evenly lit, no glare, cropped to its edges.
2. **Add the image.** In `Assets.xcassets`, select **AR Resources**, drag the image in, and name
   the entry after the model it should show — prefixed `Simulation` if it should run the minigame,
   `Showcase` otherwise. (Only `Simulation` is tested for; any other prefix, or none, is a
   showcase card.)
3. **Set the physical size** in the Attributes Inspector — measure the printed card with a ruler.
   This decides how far away and how *large* the model is, so approximately right is fine but
   wrong is visible.
4. **Add the model.** Drop `<same name>.usdz` into the `PostcardAR/` folder, next to the Swift
   files. The Xcode target uses a synchronized folder group, so it is picked up automatically —
   there is no file list to maintain.
5. Build and run.

Every image in the group is tracked, and several cards can be on screen at once, each with its
own model and its own printed size.

### What usually goes wrong

| Trap | Short version |
|---|---|
| Image will not track | ARKit needs high-contrast detail spread across the *whole* image. Flat colour, gradients, white backgrounds, and AI-upscaled images fail. Xcode's asset warnings are the authority — see [docs/reference-images.md](docs/reference-images.md). |
| Model is a strange size | It isn't: `fit(_:toCardWidth:named:)` sizes every model to its card's width, so the authored scale is irrelevant. Check the physical size field instead. |
| Camera freezes, no error | The `.usdz` brought a camera from Blender. Stripped automatically at load; see [docs/models.md](docs/models.md). |
| Everything stutters | Model weight. Budget 512² textures and under ~50k triangles, *shared* across all cards — every model loads at launch and stays resident. |
| A card with no `.usdz` | Tracks fine, shows nothing, and the status panel names the missing file. |
| No minigame on a card | It is a showcase card. Only a name starting `Simulation` runs one, and the `.usdz` needs the same prefix. |
| The run restarted from zero | The card left frame with no hand in it for more than 5 seconds. Inside 5 seconds the score and clock are held; keeping a hand in frame holds the model indefinitely. |

## What it looks like inside

```
worldRoot (static)     ← one shared anchor, added once, never rewritten
  └── pivot            ← we write a smoothed world pose here, only while the card is tracked
        └── model      ← <image name>.usdz, scaled to that card at load time

AnchorEntity(.image)   ← ARKit rewrites this every frame with the card's raw pose;
                          read from, never written to
```

One branch per reference image, all built at startup. ARKit re-solves each card's pose from
scratch every frame, so the raw pose shivers; a dead-band filter on the pivot is what makes the
models sit still. The anchors themselves are never written to — RealityKit overwrites any such
write from the anchoring target, and the model appears frozen at the origin. The pivot hangs off
a shared static anchor rather than the card's own, which makes the pose ours to write — and the
visibility ours to drive too: only a tracked card can put its model on screen, and a card lost
while a hand is in frame keeps its model locked in place until the hand leaves — see
[docs/tracking.md](docs/tracking.md).

| Path | Purpose |
|---|---|
| `PostcardAR/ContentView.swift` | Start button, the camera screen's status overlay, and the minigame's UI |
| `PostcardAR/PostcardARView.swift` | `UIViewRepresentable` wrapping `ARView`, plus the `Coordinator` that owns the session, cards, filter, model loading, and pinch pickup |
| `PostcardAR/GameSession.swift` | The minigame's phases, score, and clocks |
| `PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/` | One reference image per card, each with its real-world size |
| `PostcardAR/<name>.usdz` | The model for the card of that name |
| `docs/` | Design notes, one file per area |

The camera permission string lives in the build settings as
`INFOPLIST_KEY_NSCameraUsageDescription`, not in a checked-in `Info.plist`.

## Docs

| File | Covers |
|---|---|
| [docs/reference-images.md](docs/reference-images.md) | The AR resource group: adding cards, physical size, what makes an image trackable |
| [docs/models.md](docs/models.md) | `.usdz` assets: naming, scaling to the card, weight budget, what else is in an export |
| [docs/tracking.md](docs/tracking.md) | ARKit and RealityKit: the session, anchors, the entity hierarchy, the render loop |
| [docs/smoothing.md](docs/smoothing.md) | Why the models hold still, and the three constants that tune it |
| [docs/app-shell.md](docs/app-shell.md) | SwiftUI from scratch: views, state, the UIKit bridge, the status panel |
| [docs/interaction.md](docs/interaction.md) | Pinch pickup: Vision hand-pose sampling, grab/drag/release |
| [docs/simulation.md](docs/simulation.md) | Showcase vs Simulation cards, the run's phases and clocks, what losing the card mid-run does |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause, starting from the status panel |

`CLAUDE.md` is the working agreement for AI-assisted changes to this repo — the invariants that
must not be broken, and the house rules.

## State

Working: several cards tracked at once, each showing the `.usdz` of its own name, scaled to its
own printed size, smoothed so it does not shiver, and drawn only once its own card has been
tracked — scanning one card never brings another card's model with it. Hands occlude the models
properly (ARKit people occlusion, A12 and later).

Simulation cards run the full loop: instructions, a 3 · 2 · 1, thirty seconds of pinching drupella
off the coral with the score and clock on screen, then a result with **Play Again**. A card lost
while a hand is in frame locks its model in place instead of blinking it out, so reaching for a
snail does not make it disappear, and the run carries on. A card lost with no hand freezes the run
for five seconds before wiping it — see [docs/simulation.md](docs/simulation.md).

Showcase cards do none of that: model on with the card, model off with the card.

Not implemented:

- **A fade on the hide.** A card that leaves with no hand in frame cuts its model out on the next
  frame; a short fade out and back in would read better than the cut.
- **More than one run at a time.** The first simulation card tracked claims the session; a second
  one in frame is only a model. A second run would need a second HUD, so the shape to reach for
  would be a session per card.
- **Any minigame but the drupella one.** The rules live in `GameSession` and the scoring call in
  `attemptGrab(at:)`; a different game on a different simulation card would need those split per
  card rather than shared.
- **Pinch gestures on anything but `Drupella*` entities** (scaling or spinning the model itself,
  say). If added, write to the model entity or a second pivot — never to the anchor, and not to
  the existing pivot, whose world transform is rewritten every frame.
