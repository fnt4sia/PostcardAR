# PostcardAR

An iOS app that recognises printed cards through the camera and stands a 3D model on each one.
Hold a card up, move it, tilt it — its model stays attached.

Everything is first-party Apple: SwiftUI for the shell, ARKit for image tracking, RealityKit for
rendering. No third-party dependencies, no package manager, four Swift files.

## Requirements

- **Xcode 26** or later.
- **A real iPhone or iPad.** The simulator has no camera feed and image tracking reports itself
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

**The name is the link.** A reference image called `postcard` shows `postcard.usdz`. Nothing in
the code names a card, so adding one is two files and no code change.

```
PostcardAR/
  Assets.xcassets/AR Resources.arresourcegroup/
    postcard.arreferenceimage      ← the image ARKit looks for
    menu.arreferenceimage
  postcard.usdz                    ← what appears on it
  menu.usdz
```

1. **Print the card**, and photograph it flat on, evenly lit, no glare, cropped to its edges.
2. **Add the image.** In `Assets.xcassets`, select **AR Resources**, drag the image in, and name
   the entry after the model it should show.
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

## What it looks like inside

```
AnchorEntity(.image)   ← ARKit rewrites this every frame with the card's raw pose
  └── pivot            ← we write a smoothed pose here, every rendered frame
        └── model      ← <image name>.usdz, scaled to that card at load time
```

One branch per reference image, all built at startup. ARKit re-solves each card's pose from
scratch every frame, so the raw pose shivers; a dead-band filter on the pivot is what makes the
models sit still. The anchors themselves are never written to — RealityKit overwrites any such
write from the anchoring target, and the model appears frozen at the origin.

| Path | Purpose |
|---|---|
| `PostcardAR/ContentView.swift` | Start button, and the camera screen's status overlay |
| `PostcardAR/PostcardARView.swift` | `UIViewRepresentable` wrapping `ARView`, plus the `Coordinator` that owns the session, cards, filter, and model loading |
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
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause, starting from the status panel |

`CLAUDE.md` is the working agreement for AI-assisted changes to this repo — the invariants that
must not be broken, and the house rules.

## State

Working: several cards tracked at once, each showing the `.usdz` of its own name, scaled to its
own printed size, smoothed so it does not shiver, and disappearing when its card leaves the
frame.

Not implemented:

- **A fade on tracking loss.** Models appear and disappear instantly. If that looks abrupt, fade
  over a few frames rather than cutting.
- **Gestures on the model** (pinch to scale, drag to spin independently of the card). Not
  currently wanted. If added, write to the model entity or to a second pivot — never to the
  anchor, and not to the existing pivot, whose world transform is rewritten every frame.
