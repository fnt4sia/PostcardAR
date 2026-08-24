//
//  PostcardARView.swift
//  PostcardAR
//
//  Camera view that finds printed cards and stands a 3D model on each of them.
//
//  Two independent questions, which is the whole point of the arrangement:
//
//      reference image  ->  where a card is       (ARKit anchor, pose only)
//      QR payload       ->  which model goes on it (Vision, identity only)
//
//  `rebind(to:)` joins them, and `attach(_:size:)` hangs the model the first time a QR names it.
//  See `QRCardIdentity` and docs/card-identity.md.
//
//  A model's own name decides its kind (see `simulationCardPrefix`):
//
//      Showcase     appears while its card is tracked, hides when it is not.
//      Simulation   the occlusion lock may hold it on screen under a hand, its grabbable
//                   entities enter the pinch pool, and seeing it starts a `GameSession`.
//
//  Per bound card:
//
//      worldRoot (static)     one shared anchor, added once, never rewritten
//        └── pivot            filtered world pose — ours to write, and the `isEnabled` that
//              │              drives both visibility and the occlusion lock
//              ├── mask       a quad at the card's printed size, hiding the artwork
//              ├── seafloor   shared Seafloor.usdz, unless the model brings its own ground
//              └── model      <payload>.usdz, scaled by `fit` at load time
//
//      AnchorEntity(.image)   ARKit's raw per-frame pose — read from, never written to
//
//  ARKit owns the anchors, we own the pivots, and nothing else touches either. All of it runs on
//  the main thread: the render loop fires there, and the session delegate uses the main queue
//  because `session.delegateQueue` is left nil.
//

import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit // `UIColor`, for the card mask

// MARK: - Tuning

/// A reference image whose name starts with this is a *Simulation* card and runs a minigame;
/// every other card is a *Showcase* card that only stands its model up to be looked at. See
/// `CardKind` for what the two actually do differently.
///
/// The type travels in the name for the same reason the model does: adding a card stays two
/// files and no code change, and nothing here names an individual card. Same idiom as the
/// `Drupella` prefix `PinchInteraction.collect(from:named:report:)` matches on.
private let simulationCardPrefix = "Simulation"

/// Pose filtering, applied in `hold(_:)`. Movement smaller than a dead band is treated as
/// tracking noise and refused outright; anything larger is glided toward by `smoothingFactor`
/// of the remaining gap per rendered frame (~60 fps).
///
/// The dead bands are what stop the idle shiver — reach for those first. Lowering
/// `smoothingFactor` calms real movement instead, at the cost of lag.
private let positionDeadBand: Float = 0.001         // metres
private let rotationDeadBand: Float = 2 * .pi / 180 // radians
private let smoothingFactor: Float = 0.15

// MARK: - The card mask

/// A flat quad laid over each card at its own printed size, so the printed artwork is hidden the
/// moment the card is tracked and what stands on it is the only thing to look at.
///
/// Generated rather than authored: it is exactly the card's rectangle and one flat colour, so
/// there is nothing for a `.usdz` to contribute and nothing to keep in step per card. It hangs
/// off the pivot beside the model, so it appears, hides, and locks with that card like everything
/// else on it, and it is ordinary geometry — people occlusion still draws hands in front of it.

/// What the card is painted over with: the sand of `Showcase_Biorock.usdz`'s own seafloor, so a
/// covered card reads as ground the models are standing on rather than as a coloured panel.
///
/// Sampled from `Seafloor.usdz`'s own `Bake_Sand.png` — the floor that now sits on top of it — so
/// the sliver of mask showing past the floor's edge is the same colour as the floor.
/// Measured over the sand only: the file is a UV bake and 46% of it is black padding, which drags a
/// naive average toward a muddy dark olive. Across the real pixels the mean (`#A99D88`) and the
/// per-channel median (`#A89D88`) agree to a single unit.
private let cardMaskColor = UIColor(red: 0xA9 / 255, green: 0x9D / 255, blue: 0x88 / 255, alpha: 1)

/// Roughness of the mask, copied from `Seafloor_SandMat`'s own `UsdPreviewSurface`. Near-matte, so
/// the mask takes the room's light the way the model's sand does and the two agree where they meet
/// — without a specular highlight streaking across a plane this large.
private let cardMaskRoughness: Float = 0.95

/// How much bigger than the printed card the mask is drawn, as a multiple.
///
/// Not 1.0 on purpose: the reference image is rarely cropped to the exact millimetre of the print,
/// and the pose filter is always a hair behind the card, so an exact-size mask leaves a sliver of
/// printed edge showing on one side or another. A few percent of overhang costs nothing and is
/// what makes the cover look deliberate.
private let cardMaskBleed: Float = 1.06

/// How far under the card's surface the mask sits, in metres. Models are fitted base-at-y = 0, so
/// without this a model with a flat bottom face co-planar with the mask would z-fight against it.
private let cardMaskDrop: Float = 0.001

// MARK: - Lighting

/// Brightness of the key light, in lux — RealityKit's own default for a directional light, which is
/// tuned against the albedo an ordinary texture has.
///
/// **This is the light that cannot fail**, and it is why the scene can no longer come up black. The
/// environment below is an `EnvironmentResource` built at run time from a generated image, and every
/// step of that can go wrong on a device in a way nothing here would report; a directional light is
/// a number in a component. If the environment is missing the models are lit harshly, from one side,
/// with black shadow faces — but they are *lit*, and that is a bug you can see and describe rather
/// than a dark screen.
private let keyLightIntensity: Float = 2145.7078

/// Which way the key light shines, as a rotation about the x axis applied to the light's own -z.
///
/// `-90°` would be straight down. Backing off to `-70°` tips it toward the camera's start-of-session
/// facing, so the fronts of the models catch it too and the tops are not the only lit surface.
private let keyLightPitch: Float = -70 * .pi / 180

/// Brightness of the environment every model is lit by, as a power of two: `+1` is twice as
/// bright, `-1` half as bright, `0` the environment as authored below.
///
/// **The dial for "the models are too dark".** An exponent because that is the unit
/// `ARView.Environment.ImageBasedLight` takes, and because a stop reads evenly at both ends of the
/// range in a way a linear multiplier does not. It moves the ambient fill only — `keyLightIntensity`
/// is the other half, and the one to reach for if the shadow sides are what is too dark.
private let environmentIntensityExponent: Float = 0

/// The sky the models are lit by, from straight up to straight down.
///
/// Deliberately a gradient rather than one flat colour: a uniform environment lights every face of
/// a model identically, which erases its form and makes it read as a flat cut-out pasted on the
/// camera image. Brighter above than below is what puts a highlight on the tops of the corals and
/// leaves a shadow under them.
///
/// Neutral greys on purpose. The models' textures are baked and already carry their own colour, so
/// a tinted environment would cast that tint over work that has been authored to look right.
private let skyZenithColor = UIColor(white: 1.00, alpha: 1)
private let skyHorizonColor = UIColor(white: 0.72, alpha: 1)
private let skyGroundColor = UIColor(white: 0.30, alpha: 1)

/// Size of the equirectangular image the environment is built from.
///
/// Small on purpose. RealityKit convolves this into diffuse and specular cube maps once, at start,
/// and a three-stop vertical gradient holds no detail a larger image could preserve — it would
/// only cost more to convolve.
private let skyImageSize = (width: 256, height: 128)

// MARK: - Status

/// The two things the AR session tells `ContentView` to draw.
@Observable
final class ARStatus {
    /// A showcase card carrying `ANNO*` labels is on screen — drives "TAP TO VIEW INFORMATION".
    /// Showcase-only and annotation-only: a plain showcase card has nothing to tap, and a
    /// simulation card has its own hint bar.
    var annotatedShowcaseVisible = false

    /// A hand is in frame that Vision cannot read a pinch from, nearly always one held too close
    /// to the lens — see `PinchInteraction.handTooClose`. Drawn during `playing` only.
    var handTooClose = false
}

// MARK: - View

/// SwiftUI wrapper around RealityKit's `ARView`.
///
/// Deliberately does nothing but create the view and hand it to the coordinator. A
/// `UIViewRepresentable` is a value that SwiftUI discards and rebuilds constantly, so it is the
/// wrong place to own anything that has to outlive a single `body` pass.
struct PostcardARView: UIViewRepresentable {
    let status: ARStatus
    let game: GameSession
    let annotations: AnnotationLayer

    /// Already loaded by the time this view exists — `ContentView` shows `LoadingView` until it
    /// is. Nothing here waits for anything.
    let library: ModelLibrary

    func makeCoordinator() -> Coordinator {
        Coordinator(status: status, game: game, annotations: annotations, library: library)
    }

    func makeUIView(context: Context) -> ARView {
        // `automaticallyConfigureSession` would helpfully replace our configuration with its own
        // default one — plane detection, environment texturing, none of which we want.
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.start(in: arView)
        return arView
    }

    /// Nothing flows from SwiftUI into the AR view — it is configured once and then driven by
    /// the camera. Data only flows back out, through `status`. Empty here is correct.
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Coordinator

extension PostcardARView {
    /// Owns everything that has to survive longer than one `body` pass: the session, the
    /// entities, and the per-frame filter. SwiftUI creates one of these per on-screen view and
    /// keeps it alive until the view goes away.
    final class Coordinator: NSObject, ARSessionDelegate {
        /// What a card is for, read off the front of its name — see `simulationCardPrefix`.
        ///
        /// Three things turn on this and nothing else does: whether the occlusion lock may hold
        /// the model on screen, whether its `Drupella*` entities go into the grabbable pool, and
        /// whether seeing the card starts a run.
        private enum CardKind {
            /// Look at it. The model appears while the card is tracked and hides the moment it
            /// is not — there is nothing to reach for, so nothing to protect from a hand.
            case showcase

            /// Play on it. The lock keeps the model alive under a hand, its snails are grabbable,
            /// and detecting it starts a `GameSession`.
            case simulation
        }

        /// One reference image: somewhere to stand a model, and the printed size to cut its mask
        /// and floor to. **Pose only** — nothing here says which model that is. Two reference
        /// images that a feature matcher confuses are therefore harmless: whichever one ARKit
        /// decides it matched, the anchor still lands on the card in front of the lens.
        private struct CardAnchor {
            /// The printed card's real-world size, straight off `ARReferenceImage.physicalSize`.
            /// Read for two things only: sizing the mask that covers this card, and the shared
            /// seafloor laid on it. A model's own size is deliberately not derived from it — see
            /// `modelWidths` in `ModelLibrary`.
            let size: CGSize

            /// ARKit's. Its transform is the card's raw pose, re-solved from scratch every frame.
            ///
            /// Never write to it. *Every* `AnchorEntity` carries an `AnchoringComponent`, and
            /// RealityKit re-derives an anchored entity's transform from that component each
            /// frame, silently discarding anything else. Swapping `.image` for `world: .zero` to
            /// "own" the transform does not escape this — `world` is a target like any other,
            /// and the model ends up pinned at the origin, which on screen reads as a freeze.
            let anchor: AnchorEntity
        }

        /// One model, and the branch it is drawn on. **Identity only** — a card knows what it is
        /// and nothing about where it is, until a QR payload binds it to a `CardAnchor`.
        private struct Card {
            /// The model's name, which is its `.usdz`'s name and the string printed in the QR.
            let name: String

            /// Showcase or simulation, decided by `name`'s prefix at build time of the array.
            let kind: CardKind

            /// Ours. A plain `Entity` has no anchoring component, so what we write to it stays.
            /// Parented to the shared `worldRoot`, not to an anchor — which also means RealityKit
            /// never hides it for us, so `isEnabled` is driven by hand in `onRenderFrame()`, and
            /// doubles as the occlusion lock's state. Starts off: a pivot nobody has posed yet
            /// sits at the world origin.
            let pivot: Entity

            /// Whether `attach(_:size:)` has tried to hang the model on `pivot` yet. Set even
            /// when the load fails, so a missing `.usdz` is not retried on every frame.
            var attached = false

            /// The model, once it is on the pivot. `nil` until a QR first names this card, and
            /// also if its `.usdz` failed to load.
            var model: Entity?

            /// The mask and the shared floor, and the printed size they were cut to.
            ///
            /// Held separately from the model because they belong to the **card**, not to it:
            /// under this split a model can move to a card of a different printed size, at which
            /// point both have to be re-cut. Freezing them at whatever card was bound first
            /// leaves a mask that misses the artwork it exists to hide.
            var fittings: [Entity] = []
            var fittedSize: CGSize?

            /// Where this card's model is currently being held, in world space. Compared against
            /// on re-detection instead of read back off `pivot`, and left untouched on tracking
            /// loss so the next pose glides in like any other movement, rather than snapping.
            var heldPose: Transform?

            /// Whether this card's model got any labels built by `AnnotationLayer.collect(from:
            /// in:named:report:)` — set once in `attachModels()`. Read in `onRenderFrame()` to
            /// decide `ARStatus.annotatedShowcaseVisible`, so a showcase card worth tapping can
            /// tell the player so.
            var hasAnnotations = false
        }

        private let status: ARStatus

        /// The run. Driven from the render loop, drawn by the overlays in `ContentView`.
        private let game: GameSession

        /// Name of the simulation card the current run belongs to, `nil` between runs.
        ///
        /// One run at a time: the first simulation card tracked claims the session and holds it
        /// until the run is wiped, so a second simulation card entering frame is only a model.
        private var activeSimulationCard: String?

        /// One per reference image, built in `start(in:)` and never added to afterwards. Where a
        /// card might be; never which one it is.
        private var anchors: [CardAnchor] = []

        /// One per model in the bundle, built in `start(in:)` and never added to afterwards. What
        /// a card could be; never where it is.
        private var cards: [Card] = []

        /// The model a QR has named and the anchor it is riding, joining the two arrays above.
        ///
        /// One at a time: the reader reports a single payload, so telling two QRs apart — and
        /// saying which anchor each belongs to — is not something this can do yet. See
        /// `rebind(to:)` for why the binding deliberately outlives the payload that made it.
        private var bound: (card: Int, anchor: Int)?

        /// Dropping this cancels the render-loop subscription, so it has to be held.
        private var frameSubscription: (any Cancellable)?

        /// Everything pinch pickup touches — grabbable snails, drag/release, hand-pose sampling,
        /// haptics. See `PinchInteraction.swift`'s file header for the call surface between this
        /// coordinator and it.
        private let pinch: PinchInteraction

        /// The explanation labels on every loaded model. See `Annotations.swift`.
        private let annotations: AnnotationLayer

        /// Held so a tap can be projected against the annotation dots — `handleTap(_:)` needs both
        /// the tap's location in the view and the view to project world points into.
        private weak var arView: ARView?

        /// The reference images and models, loaded once for the whole app. This coordinator is
        /// rebuilt on every scan; the library is not, which is what makes the second scan instant.
        private let library: ModelLibrary

        init(status: ARStatus, game: GameSession, annotations: AnnotationLayer,
             library: ModelLibrary) {
            self.status = status
            self.game = game
            self.annotations = annotations
            self.library = library
            self.pinch = PinchInteraction(game: game)
        }

        /// Starts tracking, builds an `anchor -> pivot` branch per reference image, and hangs each
        /// card's model on it.
        ///
        /// Nothing is loaded here any more. `ModelLibrary` did all of it before this screen was
        /// built — decoding the reference images used to happen on this thread, inside the camera
        /// screen's presentation, which is what made "Scan a Card" hang.
        func start(in arView: ARView) {
            guard ARWorldTrackingConfiguration.isSupported else {
                report("World tracking needs a real device, not the simulator.")
                return
            }

            // Whatever went wrong at load time, said once here — the library ran before this
            // coordinator existed.
            for message in library.errors { report(message) }

            // World tracking, not image tracking: image tracking has no world origin, so panning
            // past a stationary card reads to the filter as the card moving. World tracking gives
            // the image anchor a room-fixed pose instead. See docs/tracking.md.
            let referenceImages = library.referenceImages

            guard !referenceImages.isEmpty else { return }

            let configuration = ARWorldTrackingConfiguration()
            configuration.detectionImages = Set(referenceImages)
            // Required, not cosmetic: defaults to 0, under which a detected image is posed once
            // and frozen — the exact failure image tracking was chosen to avoid.
            configuration.maximumNumberOfTrackedImages = referenceImages.count

            // People occlusion: ARKit mattes hands and arms out of the rendered frame per pixel,
            // using the segmentation *depth* rather than a flat cut-out, so a hand in front of a
            // model hides it and a hand behind it does not. RealityKit applies this on its own
            // once the semantic is on — there is nothing to switch on in `ARView`.
            //
            // Needs an A12 or later, and `supportsFrameSemantics` is not advice: setting an
            // unsupported semantic throws. Older devices simply draw models over the hand.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                configuration.frameSemantics.insert(.personSegmentationWithDepth)
            }

            // Off, and this is the fix for "the model is dark up close and bright further away".
            //
            // Enabled — which is the default, and what this ran with until now — ARKit measures one
            // `ambientIntensity` for the *whole camera frame* each update and RealityKit scales the
            // environment by it. That estimate is a reading of the framing, not of the light on the
            // card: leaning in fills the frame with one dark printed card and puts the phone's own
            // shadow across it, so the estimate collapses and every model dims; pulling back lets
            // the ceiling and the walls in and it jumps straight back up. The model's brightness
            // ends up tracking how the phone is being held.
            //
            // With it off there is no estimate to publish, and `studioEnvironment()` below is the
            // only thing lighting the scene — the same in every room, at every distance.
            configuration.isLightEstimationEnabled = false

            // Prefer a video format whose *still* pipeline is meaningfully higher-resolution than
            // its stream, so `scanForQRAtHighResolution()` actually gains something — not every
            // format offers one. Guarded on frame rate: dropping the stream to 30 fps to help an
            // occasional still would trade tracking smoothness, which every card pays for all the
            // time, against a QR read that has to succeed once.
            if !configuration.videoFormat.isRecommendedForHighResolutionFrameCapturing,
               let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing,
               hiRes.framesPerSecond >= configuration.videoFormat.framesPerSecond {
                configuration.videoFormat = hiRes
            }

            arView.session.delegate = self // For errors only — see the note on the render loop.
            arView.session.run(configuration)

            // Our own sky, in place of the one ARKit was deriving from the camera. `nil` if it
            // could not be built, which leaves RealityKit's own default environment — dimmer and
            // flatter, but still constant, since the light estimate is off either way.
            //
            // **Read once, written once, on purpose.** `ARView.environment` is a *struct* behind a
            // get/set pair, so `arView.environment.lighting.resource = x` is a whole read-modify-
            // write of the environment — background, lighting and reverb together. Two of those in
            // a row means the second one writes back whatever the getter handed it for the fields
            // the first one set, and `background` is the field that matters: lose it and the
            // passthrough camera is replaced by a flat colour, which reads as the app having gone
            // completely dark rather than as a lighting bug. Setting `.cameraFeed()` explicitly in
            // the same write says what the background is rather than trusting it to survive.
            var environment = arView.environment
            environment.background = .cameraFeed()
            environment.lighting.resource = studioEnvironment()
            environment.lighting.intensityExponent = environmentIntensityExponent
            arView.environment = environment

            self.arView = arView
            pinch.attach(to: arView)

            // Tap to open an annotation. The one touch gesture in the app, and it reaches only the
            // annotation dots — see `handleTap(_:)`. SwiftUI's Close button and the run's panels sit
            // in overlays *above* the `ARView`, so a tap on either never arrives here.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tap)
            annotations.prepareHaptics()

            // Fixed at the world origin and never rewritten — a static parent so pivots stay in
            // the visible tree even when their own image anchor goes untracked.
            let worldRoot = AnchorEntity(world: .zero)
            arView.scene.addAnchor(worldRoot)

            // The key light, and the reason a missing environment can no longer black the scene out
            // — see `keyLightIntensity`. A *child* of the anchor, never the anchor itself: an
            // `AnchorEntity`'s transform is RealityKit's to write, so the rotation has to go
            // somewhere it will survive. A directional light shines along its entity's -z, so
            // pitching that down is the whole aim.
            let keyLight = Entity()
            keyLight.components.set(DirectionalLightComponent(intensity: keyLightIntensity))
            keyLight.orientation = simd_quatf(angle: keyLightPitch, axis: [1, 0, 0])
            worldRoot.addChild(keyLight)

            // Every anchor goes in up front. An image anchor draws nothing and costs nothing
            // until ARKit tracks its image, so the ones not on camera are free.
            for image in referenceImages {
                // An unnamed entry cannot be anchored to. Xcode names them from the filename, so
                // this is close to unreachable.
                guard let name = image.name else { continue }
                let anchor = AnchorEntity(.image(group: arResourceGroupName, name: name))
                arView.scene.addAnchor(anchor)
                anchors.append(CardAnchor(size: image.physicalSize, anchor: anchor))
            }

            // Then a branch per *model*, since that is what a QR payload names. Nothing is hung
            // on one here — see `attach(_:size:)` for what waits and why.
            for name in library.modelNames {
                let pivot = Entity()
                // Off until a QR names this model *and* an anchor is tracked. A pivot hangs off
                // the static `worldRoot`, not off an image anchor, so nothing hides it for us:
                // left enabled it would draw its model at the world origin — the spot the session
                // started at — from the moment the `.usdz` loads, which on camera looks like some
                // other card's model standing on the card you are pointing at.
                pivot.isEnabled = false
                worldRoot.addChild(pivot)
                cards.append(Card(
                    name: name,
                    kind: name.hasPrefix(simulationCardPrefix) ? .simulation : .showcase,
                    pivot: pivot
                ))
            }

            subscribeToRenderLoop(of: arView)
        }

        func session(_ session: ARSession, didFailWithError error: any Error) {
            report(error.localizedDescription)
        }

        /// Opens or closes the annotation nearest the tap.
        ///
        /// Deliberately the *only* thing a touch does anywhere in the app. It does not select, move
        /// or otherwise disturb the models: a tap that lands nowhere near a dot is ignored outright,
        /// which is what keeps "the model does not respond to touch" true everywhere it matters —
        /// the minigames are still driven entirely by the pinch, which is Vision-based and never
        /// touches the screen.
        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView else { return }
            annotations.toggle(at: recognizer.location(in: arView), in: arView)
        }

        private var reported: Set<String> = []

        /// Prints a diagnostic once — a missing `.usdz`, a malformed `.json`, a QR naming nothing.
        /// Deduplicated because `didFailWithError` can fire every frame with the same message.
        private func report(_ message: String) {
            guard reported.insert(message).inserted else { return }
            print("[PostcardAR] \(message)")
        }

        // MARK: Per-frame work

        /// Subscribes the filter to RealityKit's render loop.
        ///
        /// **Never move this to `session(_:didUpdate frame:)`.** That fires once per camera frame
        /// with an `ARFrame` attached, and the callbacks queue up behind a busy main thread, each
        /// holding its frame alive, until ARKit stops delivering images. The queue is upstream of
        /// the delegate, so storing nothing does not save you. `SceneEvents.Update` carries no
        /// frame: a slow frame means fewer events, never a backlog.
        private func subscribeToRenderLoop(of arView: ARView) {
            frameSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                self?.onRenderFrame()
            }
        }

        /// One rendered frame: hold every visible card's model at a filtered version of that
        /// card's pose, and keep the status label in step with what is actually being drawn.
        private func onRenderFrame() {
            // A hand across the card is the ordinary way tracking is lost, and it is also the
            // moment the player is reaching for something — so a hand in frame locks whatever is
            // already showing in place rather than letting it blink out. Holding a snail counts
            // as a hand regardless of what Vision managed to read on the last sample — see
            // `PinchInteraction.handInFrame`.
            let handInFrame = pinch.handInFrame

            // The first simulation card tracked this frame — what claims the session if no run
            // is under way — and whether the card the current run belongs to is on screen at all.
            var trackedSimulation: String?
            var activeCardPresent = false
            var annotatedShowcaseVisible = false

            // Where, and what — asked separately, which is the whole point of the split. ARKit
            // says an anchor is on camera; the QR says which model is printed on it, so a tracked
            // image no longer implies anything is drawn on it.
            let trackedAnchor = anchors.firstIndex { $0.anchor.isAnchored }
            rebind(to: trackedAnchor)

            // A card on camera with nothing bound to it means the QR is the only missing piece,
            // so ask the still pipeline for a frame the video stream cannot match. Self-limiting:
            // one success binds, and a binding outlives the payload, so this stops on its own the
            // moment a model appears. See `docs/card-identity.md`.
            if bound == nil, trackedAnchor != nil {
                pinch.scanForQRAtHighResolution()
            }

            for index in cards.indices {
                // Every model but the bound one stays dark. An unbound pivot has never been posed
                // and sits at the world origin — the phone's position at session start — so
                // leaving one enabled piles every model in the bundle up on that spot.
                guard bound?.card == index, let anchorIndex = bound?.anchor else {
                    if cards[index].pivot.isEnabled { cards[index].pivot.isEnabled = false }
                    continue
                }

                let tracked = anchors[anchorIndex].anchor.isAnchored
                let isSimulation = cards[index].kind == .simulation

                // The latch: only a frame that both tracks the anchor and reads a payload naming
                // *this* card may turn a pivot on. Naming this card, not merely decoding something
                // — a bare `qrPayload != nil` lets any QR in shot re-summon the last-bound model,
                // since `bound` is never cleared. And it must never summon: an unposed pivot sits
                // at the world origin, so every model would pile up at the session's start point.
                //
                // Once on, tracking keeps it and a hand in frame holds it through the tracking
                // loss that reaching into the scene causes — simulation cards only, a showcase
                // card has nothing to reach for. `.instructions` is exempt from the hand
                // requirement for the active card: the player is reading, not reaching, so
                // `handInFrame` is almost never true there and the lock would never engage.
                //
                // A hand covers the QR as surely as it covers the card, which is why `bound` is
                // not re-derived from the payload each frame — see `rebind(to:)`.
                let named = pinch.qrPayload == cards[index].name
                let instructionsExempt = game.phase == .instructions
                    && cards[index].name == activeSimulationCard
                let visible = (tracked && named)
                    || (cards[index].pivot.isEnabled
                        && (tracked || ((handInFrame || instructionsExempt) && isSimulation)))

                // Showcase-only: one is on screen only while tracked, having no lock, so `tracked`
                // alone is "on screen" for it.
                if tracked, !isSimulation, cards[index].hasAnnotations {
                    annotatedShowcaseVisible = true
                }

                if cards[index].pivot.isEnabled != visible {
                    cards[index].pivot.isEnabled = visible
                }

                if isSimulation {
                    if tracked { trackedSimulation = cards[index].name }
                    // Present, not tracked: a locked card is still a card you can play on, which
                    // is the entire point of the lock. This is what keeps a run alive under a hand.
                    if cards[index].name == activeSimulationCard { activeCardPresent = visible }
                }

                // An untracked card keeps `heldPose` — locked or hidden, the model holds its last
                // pose, so a card that comes back glides on from where it was instead of snapping.
                guard tracked else { continue }

                hold(&cards[index], on: anchors[anchorIndex].anchor)
            }

            // Guarded: Observation notifies on every set without comparing, and this runs once
            // a frame.
            if status.annotatedShowcaseVisible != annotatedShowcaseVisible {
                status.annotatedShowcaseVisible = annotatedShowcaseVisible
            }
            let handTooClose = pinch.handTooClose
            if status.handTooClose != handTooClose {
                status.handTooClose = handTooClose
            }

            updateGame(cardPresent: activeCardPresent, candidate: trackedSimulation)
            pinch.update()
            // Annotations need no per-frame work: they are entities under each card's pivot, so
            // RealityKit moves, hides and billboards them along with the model.
        }

        // MARK: The run

        /// Drives the `GameSession` from what the camera can see. `PinchInteraction.update()`
        /// reacts to the resulting phase on its own — restoring snails on a fresh run, dropping
        /// whatever is held once a run stops — since both are pinch-side bookkeeping, not this
        /// coordinator's concern.
        private func updateGame(cardPresent: Bool, candidate: String?) {
            var present = cardPresent

            // A card only claims the session once its model has arrived and turned out to hold
            // something to play with — `setup(for:)` is `nil` until then. That is what keeps the
            // instructions panel off a card whose `.usdz` is still loading, and off one that has
            // neither plant points nor snails (already reported by `collect`).
            if activeSimulationCard == nil, let candidate, let setup = pinch.setup(for: candidate) {
                activeSimulationCard = candidate
                game.begin(setup.minigame, target: setup.target)
                // `cardPresent` was worked out in the card loop above, back when no card was the
                // active one — so it is `false` on this frame however plainly the card is in
                // view. `candidate` is only ever set from a *tracked* card, so the card is there.
                // Passing the stale `false` through would send the `instructions` phase this call
                // just started straight back to `idle`, which now wipes a run whose card is gone.
                present = true
            }

            game.update(cardPresent: present)

            // Wiped: the card stayed away past the grace period. Let go of it so the next scan —
            // this card or another — starts a run from zero rather than resuming this one.
            if game.phase == .idle {
                activeSimulationCard = nil
            }
        }

        /// Writes one card's pivot in world space, filtered — dead band, then glide.
        ///
        /// ARKit re-solves each pose from scratch, so a still card still wobbles. The dead band is
        /// what kills that: a smoothing filter alone, chasing a jittering target, only jitters more
        /// slowly. See docs/smoothing.md.
        ///
        /// **Every frame writes, including the ones that ignore the movement** — those re-write the
        /// previous pose. Returning early would leave the pivot on its old *local* transform, whose
        /// world pose goes on inheriting the anchor's jitter.
        private func hold(_ card: inout Card, on anchor: AnchorEntity) {
            // The anchor's world transform *is* the card's raw pose; RealityKit has already
            // copied it there, so there is nothing to ask ARKit for. Which anchor that is comes
            // from the binding rather than from the card, since a model is not tied to an image.
            let target = anchor.transformMatrix(relativeTo: nil)
            let targetPose = Transform(matrix: target)

            // Nothing held means this card has just appeared. Take its pose as given.
            guard let current = card.heldPose else {
                card.heldPose = targetPose
                card.pivot.setTransformMatrix(target, relativeTo: nil)
                return
            }

            let moved = simd_distance(current.translation, targetPose.translation) > positionDeadBand
            let turned = angle(from: current.rotation, to: targetPose.rotation) > rotationDeadBand

            var next = current
            if moved || turned {
                next = Transform(
                    scale: targetPose.scale,
                    // Quaternions live on a unit sphere; lerping them component-wise would cut
                    // through its interior and vary the rotation speed along the way.
                    rotation: simd_slerp(current.rotation, targetPose.rotation, smoothingFactor),
                    translation: current.translation
                        + (targetPose.translation - current.translation) * smoothingFactor
                )
            }

            card.heldPose = next
            // Written in world space: RealityKit works out whatever local transform achieves it,
            // so the model is drawn at the filtered pose even though its parent still jitters.
            card.pivot.setTransformMatrix(next.matrix, relativeTo: nil)
        }

        /// Angle of the rotation taking `a` to `b`, in radians.
        private func angle(from a: simd_quatf, to b: simd_quatf) -> Float {
            // `abs` folds q and -q together — they describe the same orientation. `min` guards
            // `acos` against a dot product that rounds just past 1.
            2 * acos(min(abs(simd_dot(a.vector, b.vector)), 1))
        }

        // MARK: Binding a QR payload to an anchor

        /// Points the model a QR has named at the anchor ARKit is tracking, attaching that model
        /// the first time it is needed.
        ///
        /// **A binding outlives the payload that made it.** What stops the decode is a hand over
        /// the card or the card leaving frame — precisely what the occlusion lock exists to
        /// survive — so re-deriving `bound` each frame would delete the model exactly as the
        /// player reaches for it. A *new* name rebinds; the absence of one changes nothing. What
        /// the payload still gates is whether a pivot may be switched **on** — the latch in
        /// `onRenderFrame()`.
        private func rebind(to anchorIndex: Int?) {
            guard let anchorIndex, let payload = pinch.qrPayload else { return }

            guard let cardIndex = cards.firstIndex(where: { $0.name == payload }) else {
                // Decoded cleanly and matches no model: a QR printed with a typo, or one naming a
                // `.usdz` that is not in the bundle. Worth saying, since the symptom is otherwise
                // a card that tracks perfectly and stays empty.
                report("QR says \"\(payload)\", but there is no \(payload).usdz.")
                return
            }

            // A different model than the one on screen: put the old one away before the new one
            // appears, or both are drawn at once on the same card.
            if let previous = bound?.card, previous != cardIndex {
                cards[previous].pivot.isEnabled = false
            }
            attach(&cards[cardIndex], size: anchors[anchorIndex].size)
            bound = (card: cardIndex, anchor: anchorIndex)
        }

        // MARK: Models

        /// Hangs one card's model, mask and floor on its pivot the first time a QR names it, and
        /// offers the model to the two things that read its contents. A no-op after that.
        ///
        /// Synchronous, and fast: `ModelLibrary` already did the decoding, the camera-stripping
        /// and the scaling at launch, so all that happens here is a clone.
        ///
        /// **Late rather than at start-up, because of `size`.** The mask and the shared seafloor
        /// are cut to the printed card, and which card a model is riding is not known until its
        /// QR is read — that is the cost of letting a model outlive any one reference image.
        private func attach(_ card: inout Card, size: CGSize) {
            // The model itself, once and for good — it belongs to the card's *identity*, which is
            // what the QR settled, and is the same model whichever printed card carries it.
            if !card.attached {
                // Set before the load can fail: a missing `.usdz` must not be retried every
                // frame. The reason is already in `library.errors`, reported by `start(in:)`.
                card.attached = true
                if let model = library.model(named: card.name) {
                    card.pivot.addChild(model)
                    // Any card's model may carry `ANNO*` entities; nothing about this turns on
                    // the card's kind, so both kinds are offered to it. The pivot rather than the
                    // model is handed over as the container — see
                    // `AnnotationLayer.collect(from:in:named:report:)`.
                    card.hasAnnotations = annotations.collect(
                        from: model, in: card.pivot, named: card.name, report: report)
                    // Showcase models are looked at, not touched, so nothing in one ever enters
                    // the grabbable pool — `PinchInteraction.attemptGrab(at:)` has nothing to find
                    // on one. Which minigame a simulation card runs is read from the model's own
                    // contents, not from its name; see `Minigame.swift`.
                    if card.kind == .simulation {
                        pinch.collect(from: model, named: card.name, report: report)
                    }
                    play(in: model)
                    card.model = model
                }
            }

            guard let model = card.model else { return }

            // The mask and the floor, again whenever the printed size changes. Both are cut to
            // the *card* rather than to the model, so a model moving to a differently-sized card
            // needs new ones — which under this split is an ordinary move, not an edge case.
            guard card.fittedSize != size else { return }
            card.fittedSize = size
            for entity in card.fittings { entity.removeFromParent() }
            card.fittings.removeAll()

            let cardMask = mask(sized: size)
            card.pivot.addChild(cardMask)
            card.fittings.append(cardMask)
            // A sibling of the model, never a child of it: `fit(_:named:)` has already sized the
            // model against its own bounds, and burying the floor inside it would make every
            // later measurement of that tree wrong. `nil` for a model that ships its own ground.
            if let seafloor = library.seafloor(under: model, sizedTo: size, report: report) {
                card.pivot.addChild(seafloor)
                card.fittings.append(seafloor)
            }
        }

        /// Starts every animation a model brought with it, looping forever.
        ///
        /// **RealityKit never plays an imported animation on its own** — it loads them into
        /// `availableAnimations` and leaves them stopped. Walks the whole tree, because RealityKit
        /// hangs the animation library on whichever entity the clip targets, not the root.
        ///
        /// A no-op for a model with no animations, which is every asset in the project today —
        /// see docs/models.md for how to check whether a `.usdz` carries any.
        private func play(in entity: Entity) {
            for animation in entity.availableAnimations {
                entity.playAnimation(animation.repeat(duration: .infinity),
                                     transitionDuration: 0, startsPaused: false)
            }
            for child in entity.children { play(in: child) }
        }

        /// The quad that hides one card's printed artwork — see `cardMaskColor`.
        ///
        /// `generatePlane(width:depth:)`, not `(width:height:)`: the first builds the plane in XZ
        /// and the second in XY. The anchor's axes follow the card — x across its printed width,
        /// z down its printed height, y out of its surface — so XZ *is* the card's own plane, and
        /// the mask needs no rotation of its own.
        private func mask(sized size: CGSize) -> Entity {
            let mesh = MeshResource.generatePlane(
                width: Float(size.width) * cardMaskBleed,
                depth: Float(size.height) * cardMaskBleed
            )
            // Lit, not unlit, and matched to `Seafloor_SandMat`: this is meant to read as ground
            // the models stand on, so it has to take the room's light the way their own sand does.
            // An unlit quad renders at exactly its authored value and so drifts away from the lit
            // geometry beside it — too bright in a dim room, too flat in a bright one. Roughness
            // 0.95 and no metallic is what keeps that from costing a specular streak.
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: cardMaskColor)
            material.roughness = .init(floatLiteral: cardMaskRoughness)
            material.metallic = 0.0 // `Metallic` is float-literal only; a bare `0` reads as `Int`

            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position.y = -cardMaskDrop
            return entity
        }

        /// The fixed environment every model is lit by — see `skyZenithColor` and
        /// `environmentIntensityExponent` for the dials.
        ///
        /// **Built in code from three colours rather than bundled as an `.exr`.** The whole thing
        /// is a vertical gradient, so an authored file would carry nothing this does not and would
        /// be one more asset to keep in step with a lighting change made here.
        ///
        /// Equirectangular: the image is unwrapped onto a sphere, its top row straight up and its
        /// bottom row straight down, so a top-to-bottom gradient is a sky. Its width is never
        /// sampled unevenly here — every column is identical — which is why 256 × 128 is enough.
        ///
        /// `CGContext`'s origin is bottom-left while the image's first row is its top, so the
        /// gradient is drawn from `y = height` (the zenith) down to `y = 0` (the ground).
        private func studioEnvironment() -> EnvironmentResource? {
            let colors = [skyZenithColor.cgColor, skyHorizonColor.cgColor, skyGroundColor.cgColor]
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil,
                                          width: skyImageSize.width,
                                          height: skyImageSize.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let gradient = CGGradient(colorsSpace: space,
                                            colors: colors as CFArray,
                                            locations: [0, 0.5, 1])
            else {
                report("Could not build the scene environment. Models will be lit by RealityKit's default.")
                return nil
            }

            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: skyImageSize.height),
                                       end: .zero,
                                       options: [])

            guard let image = context.makeImage() else {
                report("Could not build the scene environment. Models will be lit by RealityKit's default.")
                return nil
            }

            do {
                return try EnvironmentResource(equirectangular: image)
            } catch {
                report("Could not build the scene environment: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
