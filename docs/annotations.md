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

### Geometry is stripped, the entity is not disabled

A marker authored as a visible cube rather than an empty would render as a stray blob on the model,
so `hideGeometry(of:)` removes `ModelComponent` from the marker and everything under it. Disabling
the entity instead would be simpler and is wrong: were a marker ever authored as the *parent* of real
geometry, it would take that with it.

The nine markers in `Showcase_Coral.usdz` are empties, so this is currently a no-op there — it exists
for the model that is not.

## Every panel starts closed, and a tap opens it

Only the dots are drawn at first. Tapping a dot shows its panel and leader line; tapping it again
hides them. It is a **toggle per dot**, not a single selection, so a reader can deliberately leave
two or three open side by side while a stray tap on open air changes nothing.

Nine panels open at once is the unreadable clump the ring layout already fights, and it is not what
anyone wants anyway — a reader looks at one part at a time. Starting closed also means the model
itself is unobstructed until something is asked for.

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

## Layout: a ring around the model

**Panels are not built at their markers.** On an anatomy model the markers are wherever the anatomy
is, and the anatomy is small: `Showcase_Coral.usdz` puts six of its nine `ANNO_*` empties within a
couple of millimetres of each other. Built in place, the panels interpenetrate into one unreadable
clump. Each is pushed out to a ring instead, with a leader line back to its point.

**The ring is around the model's vertical axis**, and that is the part worth keeping. Pushing panels
apart only within the card's plane looks right from one side and collapses from the other. Spreading
them by *angle* means that from wherever the phone happens to be, some panels are in front of the
model and some behind, and walking around the card reveals the rest — which is the behaviour that
makes them feel like part of the object.

- **Radius** — half the model's larger horizontal extent, plus `annotationRingMargin`. Measured from
  the model's own `visualBounds`, so it follows whatever `modelWidths` scaled that card to.
- **Angle** — assigned by marker height, evenly spaced. The ring therefore spirals up the model
  rather than crowding one band, and ties are broken by entity name so the arrangement is stable and
  reproducible rather than following the order the JSON happened to be written in.
- **Height** — each panel keeps its own marker's height, so its leader line stays roughly horizontal.

### Built into the pivot, not into the model

`collect(from:in:named:report:)` takes the container as a separate argument, and the `Coordinator`
passes `card.pivot`. That matters: the model carries `fit(_:named:)`'s scale factor — whatever it
took to bring that particular `.usdz` to its target width — so building inside it would make every
metre constant here a function of the asset's authored units. The pivot is plain metres.

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
| `annotationRingMargin` | How far beyond the model's silhouette the ring of panels sits |
| `annotationBoxMaxWidth` | Width the label is laid out at, so where the body text wraps and what shape the panel is |
| `annotationRenderScale` | Texture supersampling. Raise it if labels look soft when the phone is close, at the cost of texture memory |
| `annotationLeaderThickness` | Thickness of a leader line, in metres |
| `annotationDotRadius` | Size of the dot left on the marker point — the tap target as well as the marker |
| `annotationTapRadius` | How close a tap must land to a dot to toggle it, in screen points |
| `annotationLineColor` | Colour of the dots and leader lines |
