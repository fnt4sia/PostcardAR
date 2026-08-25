# Annotations

Explanation labels pinned to points inside a card's model — what they are, how to add one, and how
they are built as entities in the scene rather than drawn over it.

Everything here lives in `PostcardAR/Annotations.swift`.

## Adding one

Two halves, matched by name, exactly like a card and its `.usdz`:

1. **An entity in the model** whose name starts `ANNO`. Its transform is the point being
   described — put it on the thing, not beside it. An empty is ideal, but a marker cube works too:
   the geometry is stripped at load time.

   The prefix is matched **case-sensitively**, like every other prefix in the project, and the case
   is the assets' own: `Showcase_Coral.usdz` names its markers `ANNO_Tentacle`, `ANNO_Mouth` and so
   on. `Annotation_x` does not match.
2. **An entry in `<card name>.json`**, beside the `.usdz`:

```
PostcardAR/
  Showcase_Coral.usdz     ← contains ANNO_Tentacle, ANNO_Mouth, …
  Showcase_Coral.json     ← the words for them
```

```json
[
  { "entity": "ANNO_Tentacle", "title": "Tentacles", "body": "A ring of stinging arms…" },
  { "entity": "ANNO_Mouth",    "title": "Mouth",     "body": "The polyp's only opening…" }
]
```

Two or three lines reads best, but nothing here breaks if a body runs long: the panel is sized from
the text it actually wrapped to — see "Panels are sized by the text" below.

An array rather than an object keyed by entity name, so the file's own order is the order you
control, and editing it is editing a list rather than a tree.

The synchronized folder group copies `.json` into the app bundle with no project changes, the same
way it picks up a `.usdz` — verified rather than assumed.

**Nothing turns on the card's kind.** A model with `ANNO*` entities and a JSON file has
annotations; one without has none. That is deliberate: the showcase/simulation split governs exactly
three things (see [simulation.md](simulation.md)) and is more useful kept that way. In practice
annotations belong on showcase cards, but nothing enforces it.

### When they do not appear

Every mismatch is printed to the console, because the names have to agree exactly and nothing
else would tell you they do not:

| Panel line | Cause |
|---|---|
| `…usdz has N ANNO entities but no ….json` | The model is annotated and the text file is missing or misnamed. |
| `….json names "X", which is not in ….usdz` | Typo on the JSON side, or the entity was renamed in Blender. |
| `….usdz has "X" with no entry in ….json` | The model gained a point that has not been written up yet. |
| `Could not read ….json: …` | Malformed JSON — a trailing comma, usually. |

A card with neither entities nor a file is silent, which is the ordinary case for most cards.

## In the scene, not on the screen

The labels are RealityKit **entities**, parented to the card's pivot alongside the model. They tilt
and move with the card, are occluded by the model and by hands, and shrink with distance — they are
part of the world, not drawn over it.

An earlier version did the opposite: it projected each marker to a screen point every frame and drew
SwiftUI boxes over the camera feed. That is why some of the machinery below is about *not* needing
per-frame work any more.

### Why a texture and not a SwiftUI view

**`ViewAttachmentComponent` is visionOS-only** — verified absent from the iOS SDK, not assumed. So
a SwiftUI view cannot live in a RealityKit scene on iPhone, and there are two remaining options:

| Option | Verdict |
|---|---|
| `MeshResource.generateText` | available on iOS, and wrong here: an extruded glyph mesh with no background, no real wrapping, and a full rebuild on every text change. |
| **Render the view to a texture** | `ImageRenderer` lays `AnnotationBox` out and hands back a `CGImage`; `TextureResource(image:withName:options:)` uploads it; an `UnlitMaterial` wears it on a quad. ← used |

The payoff is that the label's *design* stays one ordinary SwiftUI view. Restyling a panel is
editing `AnnotationBox`, exactly as it was when the labels were an overlay.

`renderer.isOpaque = false` and `blending = .transparent(opacity: 1)` are a pair: the box has
rounded corners, so the texture carries alpha and the material has to blend it. `opacityThreshold`
would cut the corners out instead and leave them hard and aliased.

The material is **unlit**, unlike the card mask, and for the opposite reason: this is text to be
read, not a surface to be believed. A lit panel dims in a dim room, which is exactly when a label
most needs to stay legible.

### Nothing here runs per frame

`collect(from:in:named:report:)` builds every entity once, at load. After that RealityKit owns them:

- **Movement** — they are children of the pivot, so the smoothed card pose carries them.
- **Visibility** — the pivot's `isEnabled` hides and shows them with the model, and the occlusion
  lock holds them along with it, for free.
- **Facing the camera** — `BillboardComponent` (iOS 18+, and the project targets far past that).
  Without it a flat label is readable from one angle and edge-on from every other, which is the
  usual reason labels in a 3D scene fail.

So `AnnotationLayer` has no `update(in:)`, no `@Observable` state and no `placed` array, and
`ContentView` has no annotation overlay. The `Coordinator` no longer stores the `ARView` either —
projecting world points into the view was its only remaining reader.

### Panels are sized by the text, not by a constant

`ImageRenderer` lays `AnnotationBox` out at `annotationBoxMaxWidth` and reports whatever pixel size
the body wrapped to; the quad takes that aspect ratio. A two-line body and a four-line body both come
out correctly proportioned, with no row-height constant to keep in step — which is precisely what the
screen-space version could not do, and why its `annotationRowHeight` had to be tuned against the
longest body in the file.

`annotationMetresPerPoint` converts the laid-out size into world size, and is the one dial for how
big every label is.

The rendered image is `annotationBoxMaxWidth` plus 10 pt of horizontal padding either side — 170 pt
— so at the current 0.00045 a panel is **7.7 cm** wide, about 60% of the 13 cm `modelWidths` gives
`Showcase_Coral`. It came down from 0.0007, which made the panel 11.9 cm: 92% of the model, near
enough the same size as the thing it labelled. That was survivable while panels sat out on a ring
beside the model and merely felt crowded; once they moved to a single spot directly above it, a
panel that wide dominated the scene.

There is headroom below this before legibility suffers. The body is `.caption2`, about 11 pt in a
170 pt box, so glyphs are ~5 mm tall — roughly 43 arcmin at a 40 cm viewing distance against the
~20 arcmin that reads comfortably — and the texture is supersampled `annotationRenderScale` times,
so it stays sharp when someone leans in.

### Geometry is stripped, the entity is not disabled

A marker authored as a visible cube rather than an empty would render as a stray blob on the model,
so `hideGeometry(of:)` removes `ModelComponent` from the marker and everything under it. Disabling
the entity instead would be simpler and is wrong: were a marker ever authored as the *parent* of real
geometry, it would take that with it.

The nine markers in `Showcase_Coral.usdz` are empties, so this is currently a no-op there — it exists
for the model that is not.

## Every panel starts closed, and a tap opens it

Only the dots are drawn at first. Tapping a dot shows its panel and leader line; tapping the same
dot again hides them. A tap on open air changes nothing.

**Exactly one panel is open at a time.** Tapping a second dot puts the first away rather than adding
to it, so the reader is always looking at one label and never has to tidy up after themselves — and
a reader does look at one part at a time. Starting closed means the model is unobstructed until
something is asked for.

This is also what lets every panel share a single position: see "Layout" below. The two are one
design, not two — with panels stacked on one coordinate, a second open panel would sit exactly on
top of the first. `setOpen(_:at:)` is the single place a panel and its leader line are switched, so
a line to a panel that is not there cannot happen.

### The tap is matched by proximity, not by a hit test

`toggle(at:in:)` projects every dot to a screen point and takes the nearest within
`annotationTapRadius`, exactly as `PinchInteraction.attemptGrab(at:)` picks a snail. A RealityKit
hit test would need a `CollisionComponent` on every dot, and a dot is 6 mm across — its true
silhouette is a few points wide at arm's length, which nobody can reliably hit. Matching by
proximity makes the target as forgiving as that one constant says, independent of how large the dot
is drawn.

Dots on a card that is not on screen are skipped via `isEnabledInHierarchy` — the same guard
`attemptGrab(at:)` uses on hidden cards' snails — so a tap can never open a label belonging to a
card nobody is pointing at.

### Open state survives losing the card

A panel's own `isEnabled` is what the tap flips, and that is independent of the pivot's. The card
going out of view disables the whole branch without disturbing which panels were open, so they come
back exactly as they were. A fresh scan starts clean, because `ScannerScreen` lives in a
`fullScreenCover` and its `AnnotationLayer` is rebuilt along with the coordinator.

### Where the tap comes from

A plain `UITapGestureRecognizer` on the `ARView`, added in `Coordinator.start(in:)`. SwiftUI's Close
button and every run panel sit in overlays *above* that view, so a tap on either never reaches it —
no coordination between the two is needed.

This is the app's only touch gesture, and it is worth being clear about what it does not do: it does
not select, move, or otherwise disturb a model, and a tap landing nowhere near a dot is ignored
outright. The minigames' pinch is unrelated — Vision reads it from the camera feed, never from the
screen — so the two can never contend.

## Layout: one place, above the model

**Panels are not built at their markers.** On an anatomy model the markers are wherever the anatomy
is, and the anatomy is small: scaled to its 13 cm target width, `Showcase_Coral.usdz` puts all nine
`ANNO_*` empties within a couple of centimetres of each other. Built in place, the panels
interpenetrate into one unreadable clump. Each is pushed clear, with a leader line back to its point.

**Every panel goes to the same point: centred over the model, lifted so its bottom edge clears the
model's top by `annotationPanelClearance`.** The half-height in that sum is why `panel(title:detail:)`
reports the height it wrapped to and not only its width.

### Why not a ring

This replaced a ring of panels spread by angle around the model's vertical axis. The ring measured
out badly on the one card that uses it:

| | |
|---|---|
| Model, after `fit` | 0.130 m wide × 0.130 m tall |
| Ring radius | 0.115 m |
| Arc between 9 panels | **0.080 m** |
| Panel width | **0.105 m** |

The panels were wider than the gap between them, so they overlapped anyway — while also being spread
across nine different heights. Worse, a ring puts roughly half of them *behind* the model from
wherever the phone happens to be, so tapping a dot could open a label into the far side of the coral.
**Position that depends on where the reader is standing is exactly what reads as random.**

### Why above

Above the model is the one region nothing can occlude, from any angle, with no per-frame work to keep
it there. Out to the side is only clear from some directions; at the marker's own height is clear
from almost none.

Every panel going to the *same* point above it is then not a compromise but the point: a reader who
taps four dots in a row sees the label appear in the same place four times, and only the leader line
moves to say which part they picked. Verified by rendering the real asset offscreen — four different
annotations from one viewpoint put the panel on the same pixels.

The leader line is cleared by half the panel's **larger** side. The panel billboards, so which of its
two dimensions faces the line depends on where the reader is standing, and the larger one is the only
clearance that holds from every angle.

### Billboarding cannot be checked in the simulator

`BillboardComponent` targets the AR camera. Under `ARView(cameraMode: .nonAR)` — which is the only
way to put this scene in the simulator — it does not rotate the panel at all: from behind, the quad
renders back-face and the text comes out mirrored, and with the default `.back` face culling it
simply vanishes. That is a property of the harness, not of the app, and it is worth knowing before
someone "fixes" the culling in response to it. Offscreen rendering can verify panel *position*; only
a device verifies panel *orientation*.

### Built into the pivot, not into the model

`collect(from:in:named:report:)` takes the container as a separate argument, and the `Coordinator`
passes `card.pivot`. That matters: the model carries `fit(_:named:)`'s scale factor — whatever it
took to bring that particular `.usdz` to its target width — so building inside it would make every
metre constant here a function of the asset's authored units. The pivot is plain metres.

### Both markers ignore the tone map

The dot and the leader line wear `annotationMarkerMaterial()`, an `UnlitMaterial` built with
`applyPostProcessToneMap: false`.

Unlit is not enough on its own. An ordinary `UnlitMaterial` still goes through the renderer's filmic
tone map on the way to the screen, and that curve rolls off the top of its range — a marker authored
at pure `#FFFFFF` lands somewhere around light grey, which against a bright reef is close to
invisible. Turning the tone map off for these two is what makes white actually white.

They are the only things in the scene exempted from it, and deliberately: the models are meant to be
graded like the camera image they sit in, but a dot that says *press here* is interface, not
scenery.

### The leader line

A thin box, stretched to the gap and rotated onto it: `generateBox` builds along +z, so
`simd_quatf(from: [0, 0, 1], to: direction)` turns it, and it sits at the midpoint of the span it
covers.

It stops short of the panel's centre by half the panel's **width** — its largest silhouette radius —
so it does not spear through the billboard and out the other side whichever way the panel happens to
be turned. A line shorter than a millimetre is skipped rather than drawn, which is the degenerate
case of a panel landing on top of its own marker.

## Tuning

At the top of `Annotations.swift`:

| Constant | Does |
|---|---|
| `annotationPrefix` | The name a marker entity must start with (`ANNO`) |
| `annotationMetresPerPoint` | **How big every label is in the world.** The first dial to reach for |
| `annotationPanelClearance` | Gap between the top of the model and the bottom edge of the open panel |
| `annotationBoxMaxWidth` | Width the label is laid out at, so where the body text wraps and what shape the panel is |
| `annotationRenderScale` | Texture supersampling. Raise it if labels look soft when the phone is close, at the cost of texture memory |
| `annotationLeaderThickness` | Thickness of a leader line, in metres |
| `annotationDotRadius` | Size of the dot left on the marker point — the tap target as well as the marker |
| `annotationTapRadius` | How close a tap must land to a dot to toggle it, in screen points |
| `annotationLineColor` | Colour of the dots and leader lines |
