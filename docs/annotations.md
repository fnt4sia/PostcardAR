# Annotations

Explanation labels pinned to points inside a card's model — what they are, how to add one, and why
they are drawn in screen space rather than in the scene.

Everything here lives in `PostcardAR/Annotations.swift`.

## Adding one

Two halves, matched by name, exactly like a card and its `.usdz`:

1. **An entity in the model** whose name starts `Annotation`. Its transform is the point being
   described — put it on the thing, not beside it. An empty is ideal, but a marker cube works too:
   the geometry is stripped at load time.
2. **An entry in `<card name>.json`**, beside the `.usdz`:

```
PostcardAR/
  Showcase_postcard.usdz     ← contains Annotation_polyp, Annotation_bleaching
  Showcase_postcard.json     ← the words for them
```

```json
[
  { "entity": "Annotation_polyp",     "title": "Polyps",   "body": "Each cup is one animal." },
  { "entity": "Annotation_bleaching", "title": "Bleaching", "body": "Warm water expels the algae." }
]
```

An array rather than an object keyed by entity name, so the file's own order is the order you
control, and editing it is editing a list rather than a tree.

The synchronized folder group copies `.json` into the app bundle with no project changes, the same
way it picks up a `.usdz` — verified rather than assumed.

**Nothing turns on the card's kind.** A model with `Annotation*` entities and a JSON file has
annotations; one without has none. That is deliberate: the showcase/simulation split governs exactly
three things (see [simulation.md](simulation.md)) and is more useful kept that way. In practice
annotations belong on showcase cards, but nothing enforces it.

### When they do not appear

Every mismatch is reported to the status panel, because the names have to agree exactly and nothing
else would tell you they do not:

| Panel line | Cause |
|---|---|
| `…usdz has N Annotation entities but no ….json` | The model is annotated and the text file is missing or misnamed. |
| `….json names "X", which is not in ….usdz` | Typo on the JSON side, or the entity was renamed in Blender. |
| `….usdz has "X" with no entry in ….json` | The model gained a point that has not been written up yet. |
| `Could not read ….json: …` | Malformed JSON — a trailing comma, usually. |

A card with neither entities nor a file is silent, which is the ordinary case for most cards.

## Screen space, not 3D

An annotation is an ordinary SwiftUI view positioned at `arView.project(…)` of its entity's world
position, refreshed once per rendered frame. It is not geometry in the scene.

That is a decision, not a shortcut, and the alternatives were checked against the iOS SDK rather
than assumed:

- **`ViewAttachmentComponent`** — hosting a real SwiftUI view inside the scene — **does not exist on
  iOS**. It is visionOS-only. This is the approach that would otherwise be obviously right.
- **`MeshResource.generateText`** does exist on iOS, and is the wrong tool here. It builds an
  extruded 3D mesh per string, so every text edit is a mesh rebuild; it needs `BillboardComponent`
  (iOS 18+) to face the camera and manual distance-scaling to stay legible at a few centimetres
  wide; and it is drawn *into* the scene, so the coral and ARKit's people occlusion both cover it.

A projected SwiftUI box gets a border, padding, wrapping and legible type for free — and the whole
premise of the feature is that the words get edited often.

The cost is one `project(_:)` per label per frame. `PinchInteraction.attemptGrab(at:)` already makes
that same call for every grabbable entity in the scene, so it is a known-cheap operation here.

### The per-frame write

`AnnotationLayer.placed` is `@Observable` and rewritten every frame, which is normally the thing
[app-shell.md](app-shell.md) warns against. It is guarded by the same inequality check as
`ARStatus.detectedImages`, and that guard genuinely bites: `Placed` is `Equatable`, and a card lying
still projects to identical points frame after frame — because the pose dead band in
[smoothing.md](smoothing.md) is holding the pivot at exactly the same transform. Without the dead
band this would invalidate the overlay sixty times a second; with it, a still card costs nothing and
a moving one redraws, which is the point.

### Geometry is stripped, the entity is not disabled

`hideGeometry(of:)` removes `ModelComponent` from the annotation entity and its descendants.
`isEnabled = false` would be the obvious move and is wrong twice:

- `update(in:)` reads `isEnabledInHierarchy` to know whether the label's card is on screen at all. A
  disabled entity reports `false` forever, so the label would never draw.
- If a marker were ever authored as the *parent* of real geometry, disabling it would take that
  geometry with it.

Stripping the mesh leaves the transform live and the visibility test honest.

## Layout

The card sits a fixed `AnnotationBox.offset` above the projected point; a dot sits on the point
itself. They are two independently positioned views rather than one stack joined by a stem, because
SwiftUI's `.position(_:)` places a view's *centre* — anchoring the bottom of a stack on the point
would need the stack's height, and that height depends on how far the body text happens to wrap.
Two fixed positions need no measurement at all.

The overlay is aligned `.topLeading` so that `.position(_:)` is measured from the same origin
`arView.project(_:)` reports into. That holds because `PostcardARView` fills the screen and ignores
the safe area.

`.allowsHitTesting(false)` on the layer: labels are read, not tapped, and without it a label over the
**Close** button would swallow the tap.

**Every label is drawn at once.** With several annotations close together on one model their cards
will overlap, and the fix is to move the `Annotation*` entities apart in Blender rather than to add
code — their positions are yours, and spreading the points spreads the labels. If that stops being
enough, the shape to reach for is dots that expand on tap, which is why `AnnotationDot` is already a
separate view.

## Tuning

At the top of `Annotations.swift`:

| Constant | Does |
|---|---|
| `annotationPrefix` | The name a marker entity must start with |
| `annotationBoxOffset` | How far above its point a card sits |
| `annotationBoxMaxWidth` | Where the body text starts wrapping |
