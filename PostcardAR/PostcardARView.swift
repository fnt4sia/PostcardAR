//
//  PostcardARView.swift
//  PostcardAR
//
//  Camera view that finds printed cards and stands a 3D model on each of them.
//
//  Every reference image in the AR resource group is one card. Its `AnchorEntity(.image)` is
//  purely a pose source — ARKit rewrites its transform every frame — and is not itself in the
//  visible tree, so a card going untracked (occluded by a hand, say) does not hide anything:
//
//      worldRoot (static)     one shared anchor, added once, never rewritten
//        └── pivot            we write a filtered world pose here, only while the card is tracked
//              └── model      <image name>.usdz, scaled to that card at load time
//
//      AnchorEntity(.image)   ARKit rewrites this every frame with that card's raw pose;
//                             read from, never parented to, never written to
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

/// Model width as a fraction of its card's width — `1.0` is exactly as wide as the card.
/// The only dial for model size, because `fit(_:toCardWidth:named:)` measures the model at load
/// time and makes its authored scale irrelevant.
private let modelWidthRelativeToCard: Float = 1.0

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

    func makeCoordinator() -> Coordinator {
        Coordinator(status: status)
    }

    func makeUIView(context: Context) -> ARView {
        // `automaticallyConfigureSession` would helpfully replace our configuration with
        // ARView's default world-tracking one — plane detection, environment texturing, and its
        // own schedule, none of which we want.
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
        private struct Card {
            /// The image's name in the asset catalog, which is also its `.usdz`'s name.
            let name: String

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
            /// Parented to the shared `worldRoot`, not to `anchor` — so it keeps rendering at its
            /// last pose even while the card is occluded, instead of vanishing with the anchor.
            let pivot: Entity

            /// Where this card's model is currently being held, in world space.
            ///
            /// Kept here rather than read back off `pivot`, so a re-detected pose is compared
            /// against our own last output rather than against whatever `pivot` still shows.
            ///
            /// Left as-is while the card is untracked (occlusion or leaving frame): the next
            /// tracked pose glides in from here like any other movement, rather than snapping.
            var heldPose: Transform?
        }

        private let status: ARStatus

        /// One per reference image, built in `start(in:)` and never added to afterwards.
        private var cards: [Card] = []

        /// Dropping this cancels the render-loop subscription, so it has to be held.
        private var frameSubscription: (any Cancellable)?

        init(status: ARStatus) {
            self.status = status
        }

        /// Starts tracking, builds an `anchor -> pivot` branch per reference image, and begins
        /// loading their models.
        func start(in arView: ARView) {
            guard ARWorldTrackingConfiguration.isSupported else {
                report("World tracking needs a real device, not the simulator.")
                return
            }

            // World tracking, not image tracking: image tracking has no world origin, so a
            // card's pose comes back relative to the current camera view rather than the room —
            // panning past a stationary card reads to the filter as the card moving. World
            // tracking gives the image anchor a room-fixed pose, so a still card is a still
            // target. See "The session and its configuration" in docs/tracking.md.
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
            // Required, not cosmetic: this defaults to 0 on ARWorldTrackingConfiguration, under
            // which a detected image is posed once and frozen there — the exact "anchor left
            // where the card used to be" failure image tracking was originally chosen to avoid.
            configuration.maximumNumberOfTrackedImages = referenceImages.count

            arView.session.delegate = self // For errors only — see the note on the render loop.
            arView.session.run(configuration)

            // Fixed at the world origin and never rewritten — a static parent so pivots stay in
            // the visible tree even when their own image anchor goes untracked. See the note on
            // `AnchorEntity` in `hold(_:)`: this is never written to, only ever parented under.
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
                worldRoot.addChild(pivot)
                arView.scene.addAnchor(anchor)

                cards.append(Card(
                    name: name,
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

            for index in cards.indices {
                // While untracked (occluded, or off camera) the pivot is simply left alone: it
                // keeps rendering at `heldPose`, because it lives under `worldRoot` rather than
                // under this card's own anchor. `isAnchored` still drives the status label, so
                // the label can say "not detected" while the model keeps holding its place.
                guard cards[index].anchor.isAnchored else { continue }

                detected.append(cards[index].name)
                hold(&cards[index])
            }

            // Guarded: Observation notifies on every set without comparing values, and an
            // unguarded write here would invalidate the overlay sixty times a second.
            if status.detectedImages != detected {
                status.detectedImages = detected
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
