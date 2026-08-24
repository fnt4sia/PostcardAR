# Card identity

Which model stands on a card, and how the app decides.

Two questions are asked about every card, and they are answered by different things:

| Question | Answered by | Where |
|---|---|---|
| **Where** is the card? | ARKit, matching a reference image | `CardAnchor` |
| **What** is printed on it? | Vision, decoding a QR | `Card`, bound by the payload |

They used to be one question. A reference image was named after its model, so matching the image
*was* identifying the card. That coupling is what this splits.

## Why

Detection and discrimination are different jobs, and only one of them is easy to author.

ARKit tracks by matching small high-contrast feature neighbourhoods. Making an image that tracks
*well* is a solved problem — busy artwork, detail into all four corners, a wide histogram, see
[reference-images.md](reference-images.md). Making a set of images that also track
*distinguishably* is much harder, because a card set naturally shares its design: the same border,
the same logo, the same palette. Those shared regions are the same local neighbourhoods in every
member of the set, and the matcher has no unique fit. The usual symptom is not a wrong model but a
missing one — one card refuses to detect while another is in frame.

Under the split that stops mattering. Whichever reference image ARKit decides it matched, the
anchor still lands on the card in front of the lens, because both cards *are* in front of the lens
in the same place. The payload names the model independently. So a reference image only has to
track well, and several cards may share one image outright.

## The payload is the model's name

`Simulation_Coral`, verbatim — not an id needing a lookup table. It feeds the same
`name -> name.usdz` pairing the project already runs on, so adding a card stays "drop files, change
no code" rather than growing a registry that has to be kept in step with the bundle.

`ModelLibrary.bundledModelNames()` scans the bundle for `.usdz` (bar `Seafloor`) rather than
walking the reference images, which is the change that makes the two lists independent: a model no
longer needs a same-named reference image to exist, and a reference image no longer needs a
same-named model.

**A card's kind is read off the payload**, so a QR saying `Simulation_Coral` runs a minigame and one
saying `Showcase_Coral` does not. Same prefix rule as before, now on the string in the QR rather
than the string in the asset catalog. See [simulation.md](simulation.md).

Generated codes live in `qr/`, one per model. Use error correction level **H** — a printed card gets
handled, creased and lit badly, and H tolerates 30% of the code being unreadable.

## The mask hides the QR from the player, not from the decoder

Vision reads `ARFrame.capturedImage` — the raw sensor buffer, upstream of anything RealityKit
draws. The card mask is scene geometry composited over that image afterwards. So the QR can sit on
the printed card in plain view of the decoder and still be invisible in the finished shot, covered
by the same quad that covers the artwork. Nothing has to be left ugly for this to work.

The same is true of a hand: people occlusion is a rendering effect, so a hand drawn in front of the
model does not stop Vision reading anything. What stops Vision reading the QR is a hand physically
between the card and the lens — which is the case the next section is about.

## Binding, and why it outlives the payload

`Coordinator.rebind(to:)` joins a payload to an anchor. The rules are asymmetric on purpose:

- **A new name rebinds.** The payload names a known model, some anchor is tracked, so that model is
  bound to that anchor and attached if this is the first time.
- **The absence of a name changes nothing.** `bound` is never re-derived from the payload and never
  cleared.

That asymmetry is the whole design. `QRCardIdentity` drops a name about a second after it stops
decoding, and the two things that stop it decoding are *a hand over the card* and *the card leaving
frame* — precisely the two situations the occlusion lock exists to survive
([tracking.md](tracking.md)). Re-deriving the binding each frame would delete the model at the exact
moment the player reaches into the scene for it.

What the payload still gates is whether a pivot may be switched **on**:

```swift
let named = pinch.qrPayload == cards[index].name
let visible = (tracked && named)
    || (cards[index].pivot.isEnabled && (tracked || (handInFrame && isSimulation)))
```

| Anchor tracked | Payload names this card | Already showing | Model |
|---|---|---|---|
| yes | yes | either | drawn, pose updated |
| yes | no | yes | **stays** — the QR has done its job |
| yes | no | no | nothing; a card alone never summons a model |
| no | either | yes, hand in frame, simulation | locked, pose frozen |
| no | either | otherwise | hidden |

Row two is the ordinary steady state: you show the card, the QR reads once, and from then on the
model rides the card whether or not the code is legible.

Row three is the safety property. Two things are load-bearing here and must survive any rewrite:

1. **Only a frame that both tracks an anchor and reads a matching payload can enable a pivot.**
   Everything in `tracking.md`'s "Visibility" section applies unchanged — an unposed pivot sits at
   the world origin, so a pivot enabled without a pose piles a model onto the phone's start
   position. The QR is an *additional* condition on that latch, never a replacement for it.
2. **The payload must name the bound card, not merely decode.** A bare `qrPayload != nil` was the
   first version and it is wrong: since a binding is never cleared, any QR in shot — a URL on a
   poster, a stranger's card — re-summons whichever model was bound last, on whatever anchor
   happens to be tracked. The name has to match for the same reason the binding exists.

## Attaching late

A model is hung on its pivot the first time a QR names it, not at start-up. Nothing is *loaded*
then — `ModelLibrary` decoded everything at launch, as before, and this is a clone
([models.md](models.md)).

What has to wait is the **printed size**. The card mask and the shared seafloor are cut to
`ARReferenceImage.physicalSize`, and which card a model is riding is unknown until its QR reads.

The two halves therefore have different lifetimes, and `attach(_:size:)` treats them differently:

| Part | Attached | Why |
|---|---|---|
| model, annotations, grabbables, animations | once | they belong to the card's *identity*, which the QR settled |
| mask, seafloor | again whenever the printed size changes | they belong to the *card*, and a model can move to a card of a different size |

Freezing the second group at whatever card was bound first leaves a mask sized to the wrong card,
missing the artwork it exists to hide. Under this split moving a model between cards is the
ordinary case, not an edge case.

## Cost

Decoding shares the hand-pose sample rather than adding one. Both requests go through a single
`ImageRequestHandler`, which ingests the pixel buffer once and runs both models against it:

```swift
let handler = ImageRequestHandler(pixelBuffer, orientation: imageOrientation)
let results = try? await handler.perform(handPoseRequest, QRCardIdentity.request)
```

A second sampler alongside the first would cost a second in-flight inference and halve the
hand-pose rate that `handPoseLossTimeout` and the occlusion lock are tuned against
([interaction.md](interaction.md)). Do not add one.

The request is restricted to `[.qr]`. `DetectBarcodesRequest` scans for every symbology it is
handed, and the other thirty-odd are pure per-frame cost here.

## Resolution, and the one-off high-resolution scan

The iPhone's Camera app reads a QR from much further away than this does, and the reason is
pixels, not cleverness: it runs its detector on a full-resolution capture, while ARKit hands
Vision `capturedImage` at the video format's size — commonly 1920 × 1440. QR decoding is bounded
by *pixels per module*, so a 2× resolution gap is a 2× distance gap.

Vision wants roughly four to five pixels per module. These payloads produce 25–29 module codes at
error correction level H, so the code needs about **145 px** in the captured frame. At 1920 px
across roughly 60° of field of view that is about 4 cm of printed QR at half a metre.

`PinchInteraction.scanForQRAtHighResolution()` closes the gap without paying for it continuously.
`ARSession.captureHighResolutionFrame()` returns a single frame from the *still* pipeline — around
4032 px across — while the video stream carries on unchanged. Roughly 2.1× the linear resolution,
so roughly half the printed size.

**It works because one decode is enough.** A binding outlives its payload, so a card only ever
needs to be read once. `onRenderFrame()` fires this only while `bound == nil` *and* an anchor is
tracked, paced by `highResolutionScanInterval`, and it stops the instant a model appears. A still
capture is far too expensive to run continuously and does not have to be.

Two things keep it honest:

- **It does not feed `decodeRate`.** That window is a statistic about the video stream, answering
  "is a code this size readable during normal running" — which is the question the printed card's
  design turns on. Folding occasional still frames in would report a code as fine at a size the
  stream can never read.
- **The video format is only upgraded if it is free.** Not every format's still pipeline beats its
  stream, so `start(in:)` switches to
  `recommendedVideoFormatForHighResolutionFrameCapturing` when the default is not one — but only
  if it does not cost frame rate. Dropping the stream to 30 fps would trade tracking smoothness,
  which every card pays for all the time, against a QR read that has to succeed once.

What is *not* available here: `configurableCaptureDeviceForPrimaryCamera` returns nil when the
primary camera is used for tracking, which under `ARWorldTrackingConfiguration` it is. So exposure
and focus cannot be tuned for the code — autofocus hunting shows up as blur, and blur is not
something more pixels fix.

## Reading the status panel

Two separate lines, so a failure can be attributed:

| Line | Means |
|---|---|
| `Detected: …` | reference images ARKit is tracking — **anchors**, not models. Under this split a tracked image no longer implies anything is drawn on it. |
| `QR: <name> · N%` | the decoded model name, and the fraction of the last two seconds' samples that decoded anything |

The percentage is the number that matters, and it is reported precisely because nothing else can
tell you it is low. A QR carries its own error correction, so a payload that decodes at all has
passed a checksum — a *wrong* name is close to impossible and the only failure mode is *no* name.
Sustained high means identity can live here; intermittent means the code is being asked to decode
at a size, distance or motion blur it cannot, and no amount of wiring downstream will fix that.

`QR says "X", but there is no X.usdz.` is a payload that decoded cleanly and matched no model — a
code printed with a typo, or one naming a file that is not in the bundle. Worth an error line
because the symptom is otherwise a card that tracks perfectly and stays empty.

## Known limits

Both follow from there being one payload and one binding.

- **Two cards in frame at once** bind to whichever reference image ARKit lists first, so the model
  can land on the wrong one. `BarcodeObservation` conforms to `QuadrilateralProviding` and carries
  the code's four corner points, so the fix is to project each anchor's position into the image and
  match each payload to the nearest — it simply is not done yet.
- **Swapping one card for another** draws the outgoing model on the incoming card until the new QR
  reads, bounded by `payloadHoldSamples` (about a second).

## Tuning

Both in `QRCardIdentity.swift`, and they must not be merged — one is a statistic being reported,
the other is state the app acts on.

| Constant | Default | Does |
|---|---|---|
| `decodeRateWindow` | 30 samples (2 s) | how far back `decodeRate` averages |
| `payloadHoldSamples` | 15 samples (1 s) | how long a name survives after the last sample that read it |

`highResolutionScanInterval` (1 s) lives in `PinchInteraction.swift`, beside the sampler it
escalates from.

If a code still will not read, the levers are, cheapest first: print it bigger; shorten the
payload (a shorter model name drops the code a version, so 29 modules become 25 or 21); drop error
correction from H to M, at the cost of tolerating less handling damage.
