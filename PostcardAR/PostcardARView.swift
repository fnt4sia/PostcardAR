//
//  PostcardARView.swift
//  PostcardAR
//
//  Camera view that finds printed cards and stands a 3D model on each of them.
//
//  A card is one of two kinds, read off the front of its name (see `simulationCardPrefix`):
//
//      Showcase     the model appears while the card is tracked and hides when it is not.
//      Simulation   the occlusion lock may hold the model on screen under a hand, its
//                   `Drupella*` entities are grabbable, and seeing it starts a `GameSession`.
//
//  Every reference image in the AR resource group is one card:
//
//      worldRoot (static)     one shared anchor, added once, never rewritten
//        └── pivot            filtered world pose, written only while the card is tracked
//              └── model      <image name>.usdz, scaled to that card at load time
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

// MARK: - Status

/// What the AR session is currently doing, for the overlay in `ContentView`.
///
/// Detection and model loading are reported separately on purpose: when nothing appears on
/// screen, the only useful question is which of the two never happened.
@Observable
final class ARStatus {
    /// Names of the reference images being tracked right now, in the card order.
    var detectedImages: [String] = []

    /// Names of the cards whose model is on screen without their card being tracked — held there
    /// by the occlusion lock. Reported because the lock is otherwise invisible when it fails:
    /// a model that vanishes tells you nothing about whether the hand was seen.
    var lockedImages: [String] = []

    /// Whether a hand counts as being in frame right now — the lock's input, on screen so a
    /// failure to lock can be told apart from a failure to see the hand.
    var handInFrame = false

    /// Whether a hand is in frame that Vision cannot read a pinch from — see
    /// `PinchInteraction.handTooClose`. Drawn during `playing` only, by `ContentView`.
    var handTooClose = false

    /// The card name last decoded from a QR in the camera frame, and the fraction of recent
    /// Vision samples that decoded anything at all.
    ///
    /// Measurement only — nothing in the app acts on either yet. They are on the panel to answer
    /// the one question that decides whether card identity can move off the reference images and
    /// onto a printed QR: not "is the name right" (a QR is checksummed, so it is) but "how often
    /// does a name arrive at the distance a card is actually held". See `QRCardIdentity`.
    var qrPayload: String?
    var qrDecodeRate: Double = 0

    /// How many `.usdz` files have finished loading, out of one per reference image.
    var loadedModels = 0
    var totalImages = 0

    /// Collected rather than replaced: with several models, one missing `.usdz` must not hide
    /// the next.
    var errors: [String] = []
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
        /// One reference image and everything belonging to it.
        ///
        /// A struct, kept in an array the coordinator mutates in place. `anchor` and `pivot` are
        /// entities — classes — so a copy of the struct still refers to the same two entities;
        /// only `heldPose` needs the in-place mutation.
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

        private struct Card {
            /// The image's name in the asset catalog, which is also its `.usdz`'s name.
            let name: String

            /// Showcase or simulation, decided by `name`'s prefix at build time of the array.
            let kind: CardKind

            /// The printed card's real-world size, straight off `ARReferenceImage.physicalSize`.
            /// Read for one thing only: sizing this card's mask to cover it. The card's *model*
            /// is deliberately not sized from it — see `modelWidths` in `ModelLibrary`.
            let size: CGSize

            /// ARKit's. Its transform is the card's raw pose, re-solved from scratch every frame.
            ///
            /// Never write to it. *Every* `AnchorEntity` carries an `AnchoringComponent`, and
            /// RealityKit re-derives an anchored entity's transform from that component each
            /// frame, silently discarding anything else. Swapping `.image` for `world: .zero` to
            /// "own" the transform does not escape this — `world` is a target like any other,
            /// and the model ends up pinned at the origin, which on screen reads as a freeze.
            let anchor: AnchorEntity

            /// Ours. A plain `Entity` has no anchoring component, so what we write to it stays.
            /// Parented to the shared `worldRoot`, not to `anchor` — which also means RealityKit
            /// never hides it for us, so `isEnabled` is driven by hand in `onRenderFrame()`, and
            /// doubles as the occlusion lock's state. Starts off: a pivot nobody has posed yet
            /// sits at the world origin.
            let pivot: Entity

            /// Where this card's model is currently being held, in world space. Compared against
            /// on re-detection instead of read back off `pivot`, and left untouched on tracking
            /// loss so the next pose glides in like any other movement, rather than snapping.
            var heldPose: Transform?
        }

        private let status: ARStatus

        /// The run. Driven from the render loop, drawn by the overlays in `ContentView`.
        private let game: GameSession

        /// Name of the simulation card the current run belongs to, `nil` between runs.
        ///
        /// One run at a time: the first simulation card tracked claims the session and holds it
        /// until the run is wiped, so a second simulation card entering frame is only a model.
        private var activeSimulationCard: String?

        /// One per reference image, built in `start(in:)` and never added to afterwards.
        private var cards: [Card] = []

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

            // Whatever went wrong at load time, said once here: the status panel did not exist
            // when the library ran.
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

            arView.session.delegate = self // For errors only — see the note on the render loop.
            arView.session.run(configuration)

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

            // Every anchor goes in up front. An image anchor draws nothing and costs nothing
            // until ARKit tracks its image, so the ones not on camera are free.
            //
            // Already sorted by name, by the library — only so the status list does not reshuffle.
            for image in referenceImages {
                // An unnamed entry cannot be anchored to or matched to a `.usdz`. Xcode names
                // them from the filename, so this is close to unreachable.
                guard let name = image.name else { continue }

                let anchor = AnchorEntity(.image(group: arResourceGroupName, name: name))
                let pivot = Entity()
                // Off until this card is actually tracked. A pivot hangs off the static
                // `worldRoot`, not off its own image anchor, so nothing hides it for us: left
                // enabled it would draw its model at the world origin — the spot the session
                // started at — from the moment the `.usdz` loads, which on camera looks like
                // some other card's model standing on the card you are pointing at.
                pivot.isEnabled = false
                worldRoot.addChild(pivot)
                arView.scene.addAnchor(anchor)

                cards.append(Card(
                    name: name,
                    kind: name.hasPrefix(simulationCardPrefix) ? .simulation : .showcase,
                    size: image.physicalSize,
                    anchor: anchor,
                    pivot: pivot
                ))
            }

            status.totalImages = cards.count
            subscribeToRenderLoop(of: arView)
            attachModels()
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

        /// Adds a line to the status panel, dropping repeats. The panel is not a log, and
        /// `didFailWithError` can fire over and over with the same message.
        private func report(_ message: String) {
            guard !status.errors.contains(message) else { return }
            status.errors.append(message)
        }

        // MARK: Per-frame work

        /// Subscribes the filter to RealityKit's render loop.
        ///
        /// **Not** to `session(_:didUpdate frame:)`. That fires once per camera frame with an
        /// `ARFrame` attached, and the callbacks queue up behind a busy main thread — each one
        /// holding its frame alive — until ARKit gives up on you:
        ///
        ///     The delegate of ARSession is retaining 11 ARFrames. The camera will stop
        ///     delivering camera images…
        ///
        /// That happens without your code storing anything; the queue is upstream of the
        /// delegate. `SceneEvents.Update` carries no frame and is a step inside the render
        /// rather than a message delivered to it, so a slow frame means fewer events, never a
        /// backlog.
        private func subscribeToRenderLoop(of arView: ARView) {
            frameSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                self?.onRenderFrame()
            }
        }

        /// One rendered frame: hold every visible card's model at a filtered version of that
        /// card's pose, and keep the status label in step with what is actually being drawn.
        private func onRenderFrame() {
            var detected: [String] = []

            // A hand across the card is the ordinary way tracking is lost, and it is also the
            // moment the player is reaching for something — so a hand in frame locks whatever is
            // already showing in place rather than letting it blink out. Holding a snail counts
            // as a hand regardless of what Vision managed to read on the last sample — see
            // `PinchInteraction.handInFrame`.
            let handInFrame = pinch.handInFrame
            var locked: [String] = []

            // The first simulation card tracked this frame — what claims the session if no run
            // is under way — and whether the card the current run belongs to is on screen at all.
            var trackedSimulation: String?
            var activeCardPresent = false

            for index in cards.indices {
                let tracked = cards[index].anchor.isAnchored
                let isSimulation = cards[index].kind == .simulation

                // `pivot.isEnabled` is the lock itself. Only a tracked frame can turn it on, so a
                // card that has never been seen stays dark no matter what the hand does — which
                // is what keeps every other card's model out of the frame, since all of them load
                // at launch and an unposed pivot sits at the world origin. Once on, it stays on
                // while the card is tracked *or* a hand is in frame, and goes off the moment
                // both are gone.
                //
                // Simulation cards only. The lock exists so that reaching into the scene does not
                // delete the thing you are reaching for; a showcase card has nothing to reach for,
                // so it hides the moment its card leaves and never lingers under a passing hand.
                let visible = tracked || (cards[index].pivot.isEnabled && handInFrame && isSimulation)
                if cards[index].pivot.isEnabled != visible {
                    cards[index].pivot.isEnabled = visible
                }

                if isSimulation {
                    if tracked, trackedSimulation == nil { trackedSimulation = cards[index].name }
                    // Present, not tracked: a locked card is still a card you can play on, which
                    // is the entire point of the lock. This is what keeps a run alive under a hand.
                    if cards[index].name == activeSimulationCard { activeCardPresent = visible }
                }

                // Untracked cards keep `heldPose` — locked or hidden, the model holds its last
                // pose, so a card that comes back glides on from where it was instead of snapping.
                guard tracked else {
                    if visible { locked.append(cards[index].name) }
                    continue
                }

                detected.append(cards[index].name)
                hold(&cards[index])
            }

            // Guarded: Observation notifies on every set without comparing values, and an
            // unguarded write here would invalidate the overlay sixty times a second.
            if status.detectedImages != detected {
                status.detectedImages = detected
            }
            if status.lockedImages != locked {
                status.lockedImages = locked
            }
            if status.handInFrame != handInFrame {
                status.handInFrame = handInFrame
            }
            let handTooClose = pinch.handTooClose
            if status.handTooClose != handTooClose {
                status.handTooClose = handTooClose
            }
            let qrPayload = pinch.qrPayload
            if status.qrPayload != qrPayload {
                status.qrPayload = qrPayload
            }
            // Changes at the sampler's 15 Hz, not the render loop's 60 — the guard drops three
            // writes in four, same reason as every other field here.
            let qrDecodeRate = pinch.qrDecodeRate
            if status.qrDecodeRate != qrDecodeRate {
                status.qrDecodeRate = qrDecodeRate
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
            // neither plant points nor snails (already reported to the status panel).
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
        /// Image tracking keeps no history: frame 200's answer owes nothing to frame 199's, and
        /// each is a fit to feature points in a noisy, motion-blurred image. So a card lying
        /// still still yields a pose that moves a millimetre and a degree at a time. Refusing to
        /// move at all below a threshold is what makes the model sit *still* — a smoothing
        /// filter alone, chasing a jittering target, only jitters more slowly.
        ///
        /// Note that every frame writes, including the frames that decide to ignore the
        /// movement: those re-write the previous pose. Returning early instead would leave the
        /// pivot keeping its old *local* transform, and its world pose would go on inheriting
        /// the anchor's jitter — the noise would pass straight through.
        private func hold(_ card: inout Card) {
            // The anchor's world transform *is* the card's raw pose; RealityKit has already
            // copied it there, so there is nothing to ask ARKit for.
            let target = card.anchor.transformMatrix(relativeTo: nil)
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

        // MARK: Models

        /// Hangs each card's model on its pivot, and offers it to the two things that read a
        /// model's contents.
        ///
        /// Synchronous, and fast: `ModelLibrary` already did the decoding, the camera-stripping
        /// and the scaling, so all that happens here is a clone per card. A card whose `.usdz`
        /// failed to load has no model and is simply skipped — the reason is already in
        /// `library.errors`, reported by `start(in:)`.
        private func attachModels() {
            for card in cards {
                guard let model = library.model(named: card.name) else { continue }
                card.pivot.addChild(model)
                // Any card's model may carry `ANNO*` entities; nothing about this turns on the
                // card's kind, so both kinds are offered to it. The pivot rather than the model is
                // handed over as the container — see `AnnotationLayer.collect(from:in:named:report:)`.
                annotations.collect(from: model, in: card.pivot, named: card.name, report: report)
                // Showcase models are looked at, not touched, so nothing in one ever enters the
                // grabbable pool — `PinchInteraction.attemptGrab(at:)` has nothing to find on one.
                // Which minigame a simulation card runs is read from the model's own contents, not
                // from its name; see `Minigame.swift`.
                if card.kind == .simulation {
                    pinch.collect(from: model, named: card.name, report: report)
                }
                card.pivot.addChild(mask(for: card))
                // A sibling of the model, never a child of it: `fit(_:named:)` has already sized the
                // model against its own bounds, and burying the floor inside it would make every
                // later measurement of that tree wrong. `nil` for a model that ships its own ground.
                if let seafloor = library.seafloor(under: model, sizedTo: card.size, report: report) {
                    card.pivot.addChild(seafloor)
                }
                play(in: model)
                status.loadedModels += 1
            }
        }

        /// Starts every animation a model brought with it, looping forever.
        ///
        /// **RealityKit never plays an imported animation on its own.** It loads them into
        /// `availableAnimations` and leaves them stopped, so a `.usdz` that animates perfectly well
        /// in Blender or Quick Look simply stands still here until something calls this.
        ///
        /// Walks the whole tree rather than looking only at the root: RealityKit hangs an
        /// `AnimationLibraryComponent` on whichever entity the clip actually targets, which for a
        /// Blender export is usually the animated object rather than the scene root.
        ///
        /// Safe on every card. A model with no animations has nothing in `availableAnimations` and
        /// this does nothing, which is the case for every asset in the project today — see
        /// "Animation has to be exported *and* played" in `docs/models.md` for how to check whether
        /// a given `.usdz` actually carries any.
        ///
        /// Started once, here, rather than on each detection: the clips loop forever, so a card
        /// coming into view shows one already running instead of restarting it. `model` is a clone
        /// (`ModelLibrary.model(named:)`), and cloning copies components, so each card animates on
        /// its own without disturbing the library's pristine copy.
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
        private func mask(for card: Card) -> Entity {
            let mesh = MeshResource.generatePlane(
                width: Float(card.size.width) * cardMaskBleed,
                depth: Float(card.size.height) * cardMaskBleed
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
    }
}
