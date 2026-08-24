# 3D models

What appears on a card, and what makes a `.usdz` usable here.

## Naming and placement

Drop each `.usdz` directly into the `PostcardAR/` folder, next to the Swift files, named exactly
after its reference image:

```
PostcardAR/
  Assets.xcassets/AR Resources.arresourcegroup/
    Simulation_coral_with_drupella.arreferenceimage   ← the image ARKit looks for
    Showcase_postcard.arreferenceimage
  Simulation_coral_with_drupella.usdz                 ← what appears on it
  Showcase_postcard.usdz
```

The target uses a synchronized folder group, so Xcode picks up new files with no further action,
and nothing has to be registered in code. Renaming a model means renaming its reference image to
match — that pairing is the whole mechanism.

The `Simulation` / `Showcase` prefix is part of the name, so it has to appear on both halves. It
decides whether the card runs a minigame — see [simulation.md](simulation.md). A model on a
simulation card wants `Drupella*` entities in it to be pinched off; on a showcase card those are
never collected and the model is scenery.

A card with an image but no matching `.usdz` still tracks; it just shows nothing, and the status
panel names the missing file. A `.usdz` with no matching image is never loaded.

## Sizing

### The problem

A `.usdz` stores real-world units. RealityKit honours them literally: a model authored two metres
tall renders two metres tall, hanging over a 15 cm postcard.

Nothing connects the two. The anchor supplies position and rotation, never scale. The card's
physical size positions the anchor and never touches the model. They are independent, which is
exactly why the model appears at an arbitrary size.

### The fix

Rather than demand every `.usdz` be authored at the correct size, `fit(_:named:)` measures it at
load time and derives the scale from a fixed target width for that card:

```swift
let bounds = model.visualBounds(relativeTo: nil)
let targetWidth = modelWidths[name] ?? defaultModelWidth
let scale = targetWidth / bounds.extents.x
model.scale = .init(repeating: scale)

model.position = [
    -bounds.center.x * scale,
    (bounds.extents.y / 2 - bounds.center.y) * scale,
    -bounds.center.z * scale
]
```

`visualBounds` returns a `BoundingBox` with a `center` and `extents` (full width, not half),
computed over the entity and all its descendants.

The scale line is straightforward: to make width `extents.x` become `targetWidth`, multiply by
their ratio.

The position line handles a detail that bites everyone: **the `.usdz` origin is wherever the
artist left it.** Often it is at the model's feet, sometimes off to one side, rarely at the
centre. Assuming it is centred is why models show up half-buried or floating beside the card.

So we measure and correct. In the anchor's coordinate space, x runs across the card's width,
z down its height, and y points out of its surface. A point `p` in the model lands at
`scale * p + position`. Solving for what we want:

- **Centred on the card** — put the box centre at the origin in x and z:
  `scale * center + position = 0`, so `position = -scale * center`.
- **Standing on the card** — put the box *bottom* at y = 0. The bottom is
  `center.y - extents.y / 2`, so `position.y = scale * (extents.y / 2 - center.y)`.

The payoff is that the model's authored scale stops mattering. Export from Blender at any size;
it still lands at exactly `targetWidth`.

### The one dial, per card

```swift
private let modelWidths: [String: Float] = [
    "Showcase_postcard": 0.15,
    "Simulation_coral_with_drupella": 0.35,
]
private let defaultModelWidth: Float = 0.2
```

Deliberately **not** derived from the card's printed width (`ARReferenceImage.physicalSize`) —
that field controls tracking distance/scale for ARKit, and tying model size to it as well meant a
small card and a large card could never carry equally-sized models, or a physically accurate
reference image could force an awkwardly large or small model. Each card gets its own metres
value here instead; add an entry for a new card, or it falls back to `defaultModelWidth`.

Tune per card by eye: raise a card's number if its model reads too small, lower it if too big.
Nothing else changes — `fit` re-measures and re-derives the scale from whatever `.usdz` is there,
so the authored size of the model never needs touching.

If a model is very tall or very deep, matching widths may not be the right rule. In that case
divide by `bounds.extents.y` or `.z` instead of `.x` inside `fit(_:named:)`.

If the measurement fails, the scale is skipped and the reason is printed to the console. That
case is worth reporting rather than passing over quietly: a model authored in metres, left
unscaled on a card a few centimetres wide, puts the camera *inside* the model. The screen fills
with texture that barely moves, which reads as the app having frozen rather than as a sizing bug.

## The shared seafloor

`Seafloor.usdz` is not a card. It has no reference image, is never in `models`, and is laid under
every card's model as a ground plane, so a card reads as a patch of reef rather than as a model
standing on a printed rectangle.

```
pivot
  ├── mask                 ← a generated quad at the card's size, hiding the artwork
  ├── Seafloor.usdz        ← sized to the card by seafloor(under:sizedTo:report:)
  └── <card name>.usdz     ← the model, sized by fit(_:named:) to modelWidths
```

All three are siblings under the pivot, so they are rigidly attached to one another and to the card
— the smoothed card pose moves the whole branch as one. The floor is deliberately **not** a child of
the model: `fit(_:named:)` measures the model against its own bounds, and burying the floor inside
it would corrupt every later measurement of that tree.

### Sized to the card, and never past it

The opposite of the rule for models, and deliberately: a model's size is an artistic choice that has
to stay free of the card's printed size (see "The one dial, per card" above), whereas matching the
card *is* this thing's whole job. So the input is `ARReferenceImage.physicalSize`.

The scale is uniform and taken as a **`min`** — a *contain* fit, so the floor never spills past the
card's edge. That costs nothing, because the asset is authored to the card's proportions:

| | Measured | Aspect |
|---|---|---|
| card (6 in, 5855 × 7605) | 15.24 × 19.80 cm | 0.7699 |
| `Seafloor_Sand_m` | 9.747 × 12.682 units | 0.7686 |
| **floor as placed** | **15.21 × 19.80 cm** | — |

0.26 mm short on width, exact on depth. The card mask underneath is a few percent larger and the
same sand colour, so that hairline is covered. Should a future card have a different aspect ratio,
`min` keeps the floor inside its edges instead of hanging over the table.

Only `Seafloor_Sand*` is measured, not the whole model — the pebbles and weeds scatter past the
sand's edge, so sizing by the full `visualBounds` would leave the sand itself *smaller* than the
card. It is matched by **prefix**, because the asset has already been re-authored once and renamed
that prim from `Seafloor_Sand` to `Seafloor_Sand_m` along the way.

### Models are planted in it, not balanced on it

This is the part that fixes "the model looks like it is flying", and it is a single sign.

`fit(_:named:)` stands every model with its base at y = 0. The floor is placed by its **top**, and
`seafloorEmbed` puts that top *above* y = 0 rather than below it — so the model's base is sunk a
little into the sand instead of resting on it.

That has to be positive, and roughly the sand's own undulation. The sand is a sculpted surface, not
a flat one: 4.60 mm of variation once scaled to a 6-inch card. A model whose base sat exactly at the
sand's bounding-box *top* would touch only the highest dune and visibly hover over everything lower,
which is precisely how the earlier version — which pushed the floor 3 mm *down* — went wrong.
`seafloorEmbed` of 4 mm puts the base near the average surface, and contact reads as solid from
every angle.

### The model has to fit its floor

The floor is the card's size, so a model much wider than the card cannot look attached to it however
carefully it is seated. `Showcase_Coral` was sized to 0.3 m against a 15.2 cm floor — very nearly
twice its width — and was brought down to 0.13 m when the floor came back. Anything up to about 0.14
stays inside.

A card whose model ships its own ground is exempt, because it gets no shared floor at all.

### A model with its own ground gets none

`seafloor(under:sizedTo:report:)` returns `nil` if the card's own model already contains an entity
named `Seafloor*` — the same declare-by-naming idiom as the rest of the content API.
`Showcase_Biorock.usdz` ships 115 `Seafloor_*` prims of its own; stacking a second floor under them
only z-fights.

### Weight

71 mesh prims and 6 baked textures, the largest a 2048² `Bake_Sand.png`. Clones share
`MeshResource` and materials, so the texture memory is paid **once** however many cards use it — but
draw calls are per instance, so N cards showing it at once is 71 × N. That is the number to watch if
the frame rate drops, not the file size.

## Hiding the card under the model

The printed card is not meant to be looked at once it has been found. Every card gets a flat quad
laid over it at its own printed size, in sand colour, so the artwork disappears the instant
tracking starts and reads as ground the model is standing on.

```
pivot
  ├── <card name>.usdz     ← the model, sized by fit(_:named:) to modelWidths
  └── mask                 ← a generated quad, sized to the card itself
```

It is generated in `Coordinator.mask(for:)`, not authored: it is exactly the card's rectangle in
one colour, so there is nothing for a `.usdz` to contribute and nothing to keep in step per card.
Adding a card still means two files.

### The colour is sampled from the seafloor sitting on it

`cardMaskColor` is not picked by eye. It is averaged from `Seafloor.usdz`'s own `Bake_Sand.png` —
the floor that now covers the card — so the hairline of mask showing past the floor's contain fit is
the same colour as the floor.

**Sample the sand only.** That PNG is a UV bake and 46% of it is black padding, so a naive average
comes out a muddy dark olive. Over the real pixels the mean (`#A99D88`) and the per-channel median
(`#A89D88`) agree to a single unit.

Same method works for any future asset: find the mesh's `material:binding`, follow `diffuseColor` to
its `UsdUVTexture`, check nothing tints it, then average that file ignoring the padding.

### Three details worth keeping if it is reworked

| Detail | Why |
|---|---|
| `generatePlane(width:depth:)`, never `(width:height:)` | the first builds the plane in XZ, the second in XY. The anchor's axes follow the card — x across its printed width, z down its printed height, y out of its surface — so XZ *is* the card's plane and the mask needs no rotation of its own. |
| `PhysicallyBasedMaterial` at `roughness` 0.95, `metallic` 0 | copied from `Seafloor_SandMat`'s own `UsdPreviewSurface`. The mask has to take the room's light the way the models' sand does, or the two disagree where they meet — an unlit quad renders at exactly its authored value and drifts, too bright in a dim room and too flat in a bright one. Near-matte and non-metallic is what buys that without a specular highlight streaking across a plane this large. |
| `cardMaskBleed`, above 1.0 | a reference image is rarely cropped to the exact millimetre of the print, and the pose filter is always a hair behind the card, so an exact-size mask leaves a sliver of printed edge showing on one side. A few percent of overhang is what makes the cover look deliberate. |

`cardMaskDrop` sits it a millimetre under the card plane, because models are fitted base-at-y = 0
and one with a flat bottom face would otherwise z-fight against the mask.

It hangs off the pivot beside the model, so it appears, hides and locks with that card like
everything else on it, and it is ordinary geometry — people occlusion still draws hands in front
of it. All four constants are at the top of `PostcardARView.swift`.

## What else is in your .usdz

A `.usdz` is a scene, not a mesh. Exporting from Blender takes everything in the scene with it —
the key/fill/rim lights, the environment light, and **the viewport camera**.

The camera is the dangerous one. RealityKit turns a USD `Camera` prim into a real
`PerspectiveCamera` entity, and putting one into an `ARView` scene hands rendering over to it.
The passthrough video stops following the device and the app looks completely frozen. There is no
error, nothing in the console, and it happens the moment the model is added to the scene — so it
looks like a hang in whatever code ran last, not like an asset problem.

`ModelLibrary.removeCameras(from:)` strips them at load time, so this is handled for any model you
drop in — `Showcase_Biorock.usdz` ships one. Do not remove that call.

The **world** is the second dangerous one, for the same reason and less obviously —
`ModelLibrary.removeImportedLighting(from:)` strips that. See "Your Blender lights do not come with
it, except the world" below. The remaining lights import as inert entities and are harmless.

To see what an asset actually contains, dump the prim types:

```sh
unzip -o model.usdz -d /tmp/model && cd /tmp/model
usdcat --flatten *.usdc | grep -oE '^\s*def [A-Za-z]+ "[^"]+"' | sort | uniq -c | sort -rn
```

Anything that is not `Mesh`, `Xform`, `Material`, `Shader`, or `Scope` is worth a second look.
Cleaner still is to fix it at the source: in Blender's USD exporter, uncheck cameras and lights,
or select only the mesh and export selection.

Diagnose an imported asset by walking the loaded entity tree and printing components, rather than
by reading the file size — the shipped coral is 9 MB and froze the camera, while a 52 MB model
did not.

### Your Blender lights do not come with it, except the world

They are *in* the file — every model here exports several (`DomeLight "env_light"`, `SphereLight
"Light"`, and `Simulation_Drupella.usdz` also carries a `DistantLight "Sun"` and three
`RectLight`s). The punctual ones — sphere, distant, rect — import as inert entities and light
nothing. There is no setting that turns them on, and this is not a bug to work around.

**The `DomeLight` is the exception, and it is not inert.** Since iOS 18 RealityKit imports a USD
`DomeLight` as an `ImageBasedLightComponent`, and an image-based light on an entity *overrides* the
scene's own environment for that entity's whole subtree. Whatever `ARView.environment.lighting` is
set to simply stops reaching the model — silently, with nothing in the console.

Every `.usdz` here ships one and every one of them is near-black. Blender bakes a constant world
colour to a one-pixel `.exr` named after its hex, so you can read them straight out of the archive:

```sh
unzip -l model.usdz | grep textures/color_
#  Showcase_Coral.usdz     -> textures/color_0C0C0C.exr    (RGB 12,12,12)
#  Showcase_Drupella.usdz  -> textures/color_191C21.exr    (RGB 25,28,33)
#  Simulation_Drupella.usdz-> textures/color_191C21.exr
```

A model lit by a #0C0C0C sky renders almost black whatever the room is doing, which is exactly what
it looked like. `ModelLibrary.removeImportedLighting(from:)` removes
`ImageBasedLightComponent` and `ImageBasedLightReceiverComponent` from every entity in the tree at
load, next to the camera strip and for the same reason. Do not remove that call. Cleaner still is
to fix it at the source: uncheck lights in Blender's USD exporter.

### How models are actually lit

By a key light and a fixed environment, both the same in every room — **not** by the camera probe.

**The key light** is a `DirectionalLightComponent` at `keyLightIntensity` (2145.7 lux, RealityKit's
own default for one), on a plain `Entity` parented to `worldRoot` and pitched `keyLightPitch` — 70°
down rather than 90°, so it lands on the fronts of the models and not only their tops. A directional
light shines along its entity's **-z**, so aiming one is rotating it. It goes on a *child* of the
anchor because an `AnchorEntity`'s own transform is RealityKit's to write; see "Never write to an
anchor" in [tracking.md](tracking.md).

**The environment** is the ambient half. `Coordinator.studioEnvironment()` renders a three-stop
vertical gradient (`skyZenithColor`, `skyHorizonColor`, `skyGroundColor`) into a 256 × 128
`CGImage`, hands it to `EnvironmentResource(equirectangular:)`, and assigns it to
`arView.environment.lighting.resource`. `environmentIntensityExponent` scales it as a power of two.

Which dial to reach for: `environmentIntensityExponent` if the whole model is too dark,
`keyLightIntensity` if it is the *shadow* sides that are.

**Do not delete the key light as redundant.** The environment is assembled at run time from a
generated image and a resource initialiser, and each step can fail on a device with nothing on
screen to say so. A directional light is a number in a component. With it, a failed environment is
harsh one-sided lighting — visible, describable. Without it, it was a black screen.

`arView.environment` is read once into a local, mutated, and written back once. It is a struct
behind a get/set pair, so touching one field at a time is a full read-modify-write of background,
lighting *and* reverb; do two in a row and the second undoes the first. `background` is set to
`.cameraFeed()` explicitly in that same write rather than trusted to survive it — losing it replaces
the passthrough camera with a flat colour, which does not look like a lighting bug at all, it looks
like the app is dead.

It is a gradient rather than a flat colour on purpose: a uniform environment lights every face of a
model identically, which erases its form and reads as a cut-out pasted on the camera image.
Brighter above than below is what puts a highlight on the tops of the corals and a shadow under
them. The greys are neutral because the textures are baked and already carry their own colour — a
tinted sky would cast that tint over work authored to look right.

This replaces ARKit's light estimate, which is switched off in the session configuration. See
"Lighting" in `docs/tracking.md` for why.

The alternatives, if this is ever reworked:

| Approach | When |
|---|---|
| **Bake the lighting into the textures** | almost always, and independent of the above. It is what most of these assets already do — `BakedBaseColor`, `BakedCoral_*`, `Bake_Sand` — and it costs nothing at runtime. A model that reads flat next to a baked one has simply not been baked. |
| Change `environmentIntensityExponent` or the three sky colours | the first thing to reach for. No new asset, no new code. |
| Add real lights in code | for a key or rim light that has to follow the model. `DirectionalLightComponent`, `PointLightComponent` and `SpotLightComponent` all take `intensity` in lux. Attach one to the pivot, not to the model, so it survives cloning — and expect it to fight the baked textures, which already contain a light rig. |
| Bundle an authored `.exr` and load it with `EnvironmentResource(named:)` | only for a look a gradient cannot express. It is one more asset to keep in step with a lighting change made in code. |

### Animation has to be exported *and* played

Two separate things go wrong, and the first is the one that usually bites.

**1. Check the animation is actually in the file.** Blender's USD exporter only writes animation
when the export options ask for it, and it bakes transform and skeletal animation over the scene
frame range. It does **not** carry modifier-driven motion (unless baked first), shader/material
animation, or geometry-node effects. If your effect is a moving material, USD will not bring it —
rebuild it in Reality Composer Pro.

Grep for it before theorising about the code:

```sh
usdcat --flatten *.usdc | grep -ciE 'timeSamples|SkelAnimation|skel:|UsdSkel'
```

A count of `0` means there is no animation in the asset, whatever Blender's viewport does. Every
`.usdz` currently in this project returns `0`, `Showcase_Biorock.usdz` included — its
`PreviewFish_*` and `PrevBubble_*` entities are static geometry.

Worth checking the stage metadata too, since Blender writes these *only* when it exports animation:

```sh
usdcat --flatten *.usdc | grep -cE 'startTimeCode|endTimeCode|timeCodesPerSecond'
```

`0` there is the clearest single sign that the exporter was not asked for animation at all.

**2. RealityKit does not auto-play what it imports.** It loads clips into
`Entity.availableAnimations` and leaves them *stopped*. An asset that animates perfectly in Blender
or Quick Look therefore stands still in the app until something starts it.

`Coordinator.play(in:)` does that at load, looping forever:

```swift
for animation in entity.availableAnimations {
    entity.playAnimation(animation.repeat(duration: .infinity),
                         transitionDuration: 0, startsPaused: false)
}
for child in entity.children { play(in: child) }
```

Two details in there are load-bearing:

- **It walks the whole tree**, not just the root. RealityKit hangs an `AnimationLibraryComponent` on
  whichever entity the clip actually targets, which for a Blender export is usually the animated
  object rather than the scene root — checking only the root finds nothing and looks exactly like a
  missing animation.
- **It runs once at load, not on each detection.** The clips loop forever, so a card coming into
  view shows one already running rather than snapping back to frame zero. Models are clones
  (`ModelLibrary.model(named:)`) and cloning copies components, so each card animates independently
  and the library's pristine copy is untouched.

It is safe on every card: a model with no animations has an empty `availableAnimations` and nothing
happens.

## Weight

The scale fix says nothing about how heavy the model is, and weight is the thing most likely to
make the app feel broken. Everything runs on the main thread, alongside ARKit and SwiftUI, so a
heavy model does not degrade gracefully — it stalls the camera.

Two numbers matter, and neither is the file size:

| Budget | Why |
|---|---|
| **Texture pixels** | A 2048×2048 texture is ~16 MB decoded, ~21 MB with mipmaps, regardless of how well the PNG compressed. Six of them is ~134 MB of GPU memory. |
| **Triangles** | The model is drawn a few centimetres wide. Detail far beyond what those pixels can show costs the same as detail you can see. |

The coral model shipped here was originally 240k triangles with six 2048² textures in a 19 MB
file. The textures were reduced to 512² (`sips -Z 512`, then repacked with
`usdzip <out.usdz> --arkitAsset <root.usdc>`), which cut decoded texture memory from ~134 MB to
~8 MB and the file to 9.3 MB, with no visible difference at the size it is drawn.

Rules of thumb: **512×512 textures** and **under ~50k triangles**. Decimate in Blender (Decimate
modifier) before exporting if the source is denser. Check what you actually have rather than
trusting the file size — a `.usdz` is a zip of *uncompressed* assets, so a small file can still
be heavy, and a large one can be cheap to draw.

### The budget is shared

Every model in the group is loaded at launch and stays in memory whether or not its card is ever
shown. Ten cards means ten models resident and ten lots of texture memory.

They load one at a time, in name order: decoding is main-thread work either way, so overlapping
them would only lengthen the stall, and finishing the first card early means it is usable while
the rest arrive. `LoadingView` counts them, so a long "Loading models (2/10)…" is that queue,
not a hang.

## Authoring

- A plain `.usdz` exported from Blender, Maya, or Reality Composer Pro works directly.
- For animation, **Reality Composer Pro** (Xcode → Open Developer Tool) is the tool to use. It
  handles timeline animations, shader graph materials, particles, and spatial audio.
- The old Reality Composer app and its `.rcproject` format are gone from Xcode 26. Ignore
  tutorials that use it.
- Skeletal and transform animations in USDZ import fine, *if* the exporter was asked for them and
  something calls `playAnimation` — see "Animation has to be exported *and* played" above. Blend
  shapes are unreliable.
