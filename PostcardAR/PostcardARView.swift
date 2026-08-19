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
//                   `SeaSnail*` entities are grabbable, and seeing it starts a `GameSession`.
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

// MARK: - Tuning

/// The AR Resource Group in `Assets.xcassets`. Every reference image inside it is tracked, and
/// each one shows the `.usdz` in the bundle carrying the same name — an image called `postcard`
/// needs `postcard.usdz`. Adding a card is those two files and nothing else; there is no list
/// of names in the code to keep in step.
private let resourceGroupName = "AR Resources"

/// A reference image whose name starts with this is a *Simulation* card and runs a minigame;
/// every other card is a *Showcase* card that only stands its model up to be looked at. See
/// `CardKind` for what the two actually do differently.
///
/// The type travels in the name for the same reason the model does: adding a card stays two
/// files and no code change, and nothing here names an individual card. Same idiom as the
/// `SeaSnail` prefix `PinchInteraction.collectSnails(from:)` matches on.
private let simulationCardPrefix = "Simulation"

/// Model width as a fraction of its card's width — `1.0` is exactly as wide as the card.
/// The only dial for model size, because `fit(_:toCardWidth:named:)` measures the model at load
/// time and makes its authored scale irrelevant.
private let modelWidthRelativeToCard: Float = 2.0

/// Pose filtering, applied in `hold(_:)`. Movement smaller than a dead band is treated as
/// tracking noise and refused outright; anything larger is glided toward by `smoothingFactor`
/// of the remaining gap per rendered frame (~60 fps).
///
/// The dead bands are what stop the idle shiver — reach for those first. Lowering
/// `smoothingFactor` calms real movement instead, at the cost of lag.
private let positionDeadBand: Float = 0.001         // metres
private let rotationDeadBand: Float = 2 * .pi / 180 // radians
private let smoothingFactor: Float = 0.15

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

    func makeCoordinator() -> Coordinator {
        Coordinator(status: status, game: game)
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
        /// the model on screen, whether its `SeaSnail*` entities go into the grabbable pool, and
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

            /// The card's printed width in metres, straight off the asset catalog entry.
            let width: Float

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
        /// the crosshair, haptics. See `PinchInteraction.swift`'s file header for the call
        /// surface between this coordinator and it.
        private let pinch: PinchInteraction

        init(status: ARStatus, game: GameSession) {
            self.status = status
            self.game = game
            self.pinch = PinchInteraction(game: game)
        }

        /// Starts tracking, builds an `anchor -> pivot` branch per reference image, and begins
        /// loading their models.
        func start(in arView: ARView) {
            guard ARWorldTrackingConfiguration.isSupported else {
                report("World tracking needs a real device, not the simulator.")
                return
            }

            // World tracking, not image tracking: image tracking has no world origin, so panning
            // past a stationary card reads to the filter as the card moving. World tracking gives
            // the image anchor a room-fixed pose instead. See docs/tracking.md.
            let referenceImages = ARReferenceImage.referenceImages(
                inGroupNamed: resourceGroupName,
                bundle: nil
            ) ?? []

            guard !referenceImages.isEmpty else {
                report("No reference images in the \"\(resourceGroupName)\" group.")
                return
            }

            let configuration = ARWorldTrackingConfiguration()
            configuration.detectionImages = referenceImages
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

            pinch.attach(to: arView)

            // Fixed at the world origin and never rewritten — a static parent so pivots stay in
            // the visible tree even when their own image anchor goes untracked.
            let worldRoot = AnchorEntity(world: .zero)
            arView.scene.addAnchor(worldRoot)

            // Every anchor goes in up front. An image anchor draws nothing and costs nothing
            // until ARKit tracks its image, so the ones not on camera are free.
            //
            // Sorted only to stop the status list reshuffling: `referenceImages` is a `Set`.
            for image in referenceImages.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                // An unnamed entry cannot be anchored to or matched to a `.usdz`. Xcode names
                // them from the filename, so this is close to unreachable.
                guard let name = image.name else { continue }

                let anchor = AnchorEntity(.image(group: resourceGroupName, name: name))
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
                    width: Float(image.physicalSize.width),
                    anchor: anchor,
                    pivot: pivot
                ))
            }

            status.totalImages = cards.count
            subscribeToRenderLoop(of: arView)
            loadModels()
        }

        func session(_ session: ARSession, didFailWithError error: any Error) {
            report(error.localizedDescription)
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

            updateGame(cardPresent: activeCardPresent, candidate: trackedSimulation)
            pinch.update()
        }

        // MARK: The run

        /// Drives the `GameSession` from what the camera can see. `PinchInteraction.update()`
        /// reacts to the resulting phase on its own — restoring snails on a fresh run, dropping
        /// whatever is held once a run stops — since both are pinch-side bookkeeping, not this
        /// coordinator's concern.
        private func updateGame(cardPresent: Bool, candidate: String?) {
            if activeSimulationCard == nil, let candidate {
                activeSimulationCard = candidate
                game.begin()
            }

            game.update(cardPresent: cardPresent)

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

        /// Loads one `.usdz` per card — the file named after that card's reference image — off
        /// the critical path, so the camera appears immediately. A pivot is simply childless
        /// until its model arrives; RealityKit draws whatever is there each frame.
        ///
        /// One at a time rather than all at once: decoding happens on the main thread either
        /// way, so overlapping them would only make a longer stall, and finishing the first card
        /// early means it is usable while the rest arrive.
        private func loadModels() {
            Task { @MainActor in
                for card in cards {
                    do {
                        let model = try await Entity(named: card.name)
                        removeCameras(from: model)
                        fit(model, toCardWidth: card.width, named: card.name)
                        card.pivot.addChild(model)
                        // Showcase models are looked at, not touched, so their snails never enter
                        // the grabbable pool — `PinchInteraction.attemptGrab(at:)` has nothing to
                        // find on one.
                        if card.kind == .simulation {
                            pinch.collectSnails(from: model)
                        }
                        status.loadedModels += 1
                    } catch {
                        report("Could not load \(card.name).usdz: \(error.localizedDescription)")
                    }
                }
            }
        }

        /// Strips any camera the model brought with it.
        ///
        /// A `.usdz` is a scene, not a mesh: exported from Blender it carries the lighting rig
        /// and the viewport camera too. RealityKit turns a USD `Camera` prim into a real
        /// `PerspectiveCamera` entity, and adding one to an `ARView` scene hands rendering over
        /// to it — the passthrough video freezes, with no error and nothing in the log. Imported
        /// lights are inert and are left alone; cameras are not.
        private func removeCameras(from entity: Entity) {
            // Snapshot the children, because the recursive call can remove one of them.
            for child in Array(entity.children) {
                removeCameras(from: child)
            }
            if entity.components.has(PerspectiveCameraComponent.self) {
                entity.removeFromParent()
            }
        }

        /// Scales a model to a fixed fraction of its own card's width and sits it centred on that
        /// card, base on the surface.
        ///
        /// Anchoring supplies position and rotation, never scale, so without this the model
        /// renders at whatever real-world size it was authored at — a number with no relation to
        /// the card. Measuring at load time instead means any `.usdz` lands correctly, and every
        /// card is sized against its own printed width rather than a shared constant.
        private func fit(_ model: Entity, toCardWidth cardWidth: Float, named name: String) {
            let bounds = model.visualBounds(relativeTo: nil)

            // Worth reporting rather than skipping quietly: a model authored in metres, left
            // unscaled on a card a few centimetres wide, puts the camera inside the mesh. The
            // screen fills with texture that barely moves, which reads as a frozen app rather
            // than as a sizing bug.
            guard cardWidth > 0, bounds.extents.x > 0 else {
                report("""
                    Could not size \(name): card is \(cardWidth) m wide, model measures \
                    \(bounds.extents.x) m. Showing it at its authored size.
                    """)
                return
            }

            let scale = cardWidth * modelWidthRelativeToCard / bounds.extents.x
            model.scale = .init(repeating: scale)

            // The anchor's axes follow the card: x across its width, z down its height, y out of
            // its surface. A model point `p` lands at `scale * p + position`, and the `.usdz`
            // origin is wherever the artist left it — so centre the measured box in x and z, and
            // lift the model until the bottom of the box sits at y = 0.
            model.position = [
                -bounds.center.x * scale,
                (bounds.extents.y / 2 - bounds.center.y) * scale,
                -bounds.center.z * scale
            ]
        }
    }
}
