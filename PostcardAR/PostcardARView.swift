//
//  PostcardARView.swift
//  PostcardAR
//
//  Camera view that finds printed cards and stands a 3D model on each of them.
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
import UIKit
import Vision

// MARK: - Tuning

/// The AR Resource Group in `Assets.xcassets`. Every reference image inside it is tracked, and
/// each one shows the `.usdz` in the bundle carrying the same name — an image called `postcard`
/// needs `postcard.usdz`. Adding a card is those two files and nothing else; there is no list
/// of names in the code to keep in step.
private let resourceGroupName = "AR Resources"

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

/// Hand-pose sampling rate, deliberately slower than the render loop — see `updatePinchDetection()`.
private let handPoseSampleInterval: TimeInterval = 1.0 / 15.0

/// Thumb-to-index distance (normalized by hand size) marking closed/open. Two thresholds, not
/// one, to avoid chatter right at the pinch boundary.
private let pinchCloseRatio: Float = 0.12
private let pinchOpenRatio: Float = 0.2

/// Joint confidence floor — below this a hand-pose point is noise, not signal.
private let jointConfidenceMinimum: Float = 0.3

/// How close, in points, the pinch point must land to a snail's projected position to grab it.
private let pinchPickRadius: CGFloat = 80

/// Per-frame opacity step for a released snail — ~0.4 s fade at ~60 fps.
private let pinchFadeStep: Float = 1.0 / 24.0

/// If something's held and Vision loses the hand for this long, force a release — otherwise a
/// hand that lifts out of frame mid-grab never produces the "opened" sample to let go with.
private let handPoseLossTimeout: TimeInterval = 0.3

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

    /// Screen point of the crosshair overlay; `nil` while no hand is confidently in view.
    var pinchPoint: CGPoint?

    /// How closed the current pinch is, `0` (open) to `1` (closed) — drives the crosshair's ring.
    var pinchProgress: Float = 0
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
            /// Parented to the shared `worldRoot`, not to `anchor` — keeps rendering at its last
            /// pose while the card is occluded, instead of vanishing with the anchor.
            let pivot: Entity

            /// Where this card's model is currently being held, in world space. Compared against
            /// on re-detection instead of read back off `pivot`, and left untouched on tracking
            /// loss so the next pose glides in like any other movement, rather than snapping.
            var heldPose: Transform?
        }

        private let status: ARStatus

        /// One per reference image, built in `start(in:)` and never added to afterwards.
        private var cards: [Card] = []

        /// Dropping this cancels the render-loop subscription, so it has to be held.
        private var frameSubscription: (any Cancellable)?

        /// For projecting/raycasting and reading `session.currentFrame` in the pinch code below.
        private weak var arView: ARView?

        /// Every `SeaSnail*` entity across every loaded model, flattened.
        private var snails: [Entity] = []

        /// The snail being dragged, and the camera distance it was grabbed at (held constant for
        /// the drag). `nil` also gates pickup to one at a time.
        private var held: (entity: Entity, depth: Float)?

        /// Released snails, fading toward `opacity == 0` before `removeFromParent()`.
        private var fading: [(entity: Entity, opacity: Float)] = []

        /// Reused across samples rather than rebuilt each time.
        private let handPoseRequest: DetectHumanHandPoseRequest = {
            var request = DetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            return request
        }()

        /// Guards against overlapping inference and paces sampling to `handPoseSampleInterval`.
        private var handPoseTaskInFlight = false
        private var lastHandPoseSampleTime = Date.distantPast

        /// Debounced open/closed pinch state — see `pinchCloseRatio`/`pinchOpenRatio`.
        private var pinchClosed = false

        /// Last time a sample confidently saw a hand — what `handPoseLossTimeout` counts against.
        private var lastConfidentHandTime = Date.distantPast

        /// Screen point of the most recent pinch sample; drag reuses it between samples.
        private var pinchPoint: CGPoint?

        /// `.soft` — firm grab, gentle let-go. `prepare()`d early to hide Taptic spin-up latency.
        private var pinchHaptics: UIImpactFeedbackGenerator?

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

            arView.session.delegate = self // For errors only — see the note on the render loop.
            arView.session.run(configuration)

            self.arView = arView
            pinchHaptics = UIImpactFeedbackGenerator(style: .soft, view: arView)

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
                // While untracked, the pivot is simply left alone — it keeps rendering at
                // `heldPose` since it lives under `worldRoot`, not this card's own anchor. The
                // label can say "not detected" while the model keeps holding its place.
                guard cards[index].anchor.isAnchored else { continue }

                detected.append(cards[index].name)
                hold(&cards[index])
            }

            // Guarded: Observation notifies on every set without comparing values, and an
            // unguarded write here would invalidate the overlay sixty times a second.
            if status.detectedImages != detected {
                status.detectedImages = detected
            }

            updatePinchDetection()
            updateHeldSnail()
            updateFadingSnails()
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

        // MARK: Pinch pickup

        /// Samples the camera for a hand pinch, at most once every `handPoseSampleInterval`.
        /// Reads `session.currentFrame` from the render loop, same ARFrame-retention reason as
        /// the pose filter above — only `capturedImage` crosses into the `Task`, never the frame.
        private func updatePinchDetection() {
            guard !handPoseTaskInFlight,
                  Date().timeIntervalSince(lastHandPoseSampleTime) >= handPoseSampleInterval,
                  let arView, let frame = arView.session.currentFrame
            else { return }

            lastHandPoseSampleTime = Date()
            handPoseTaskInFlight = true

            let pixelBuffer = frame.capturedImage
            let viewportSize = arView.bounds.size
            let orientation = arView.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewportSize)

            // @MainActor so mutations below land on the same thread `onRenderFrame` runs on;
            // `perform(on:orientation:)` still suspends off it for the actual inference.
            Task { @MainActor in
                defer { handPoseTaskInFlight = false }

                // No orientation hint — Vision then leaves joints in `capturedImage`'s own
                // coordinate space, which is what `displayTransform` below expects. A hint would
                // hand back already-rotated coordinates and double-rotate the point.
                guard
                    let hand = try? await handPoseRequest.perform(on: pixelBuffer).first,
                    let thumb = hand.joint(for: .thumbTip), thumb.confidence > jointConfidenceMinimum,
                    let index = hand.joint(for: .indexTip), index.confidence > jointConfidenceMinimum,
                    let wrist = hand.joint(for: .wrist), wrist.confidence > jointConfidenceMinimum,
                    let knuckle = hand.joint(for: .indexMCP), knuckle.confidence > jointConfidenceMinimum
                else {
                    // No confident hand this sample. Hide the crosshair immediately; a held
                    // snail only force-releases after `handPoseLossTimeout`, so one dropped
                    // sample mid-hold doesn't drop it.
                    status.pinchPoint = nil
                    if pinchClosed, Date().timeIntervalSince(lastConfidentHandTime) >= handPoseLossTimeout {
                        pinchClosed = false
                        releaseHeld()
                    }
                    return
                }

                lastConfidentHandTime = Date()

                let handScale = wrist.distance(to: knuckle)
                guard handScale > 0 else { return }
                let ratio = Float(thumb.distance(to: index) / handScale)

                // Vision's normalized point is bottom-left origin; ARKit's display transform
                // expects top-left, hence the manual flip before applying it.
                let midpoint = CGPoint(
                    x: (thumb.location.x + index.location.x) / 2,
                    y: 1 - (thumb.location.y + index.location.y) / 2
                ).applying(displayTransform)
                let screenPoint = CGPoint(
                    x: midpoint.x * viewportSize.width,
                    y: midpoint.y * viewportSize.height
                )

                evaluatePinch(ratio: ratio, at: screenPoint)
            }
        }

        /// Debounces one hand-pose sample into a grab or release, and drives the crosshair
        /// overlay's position and ring fill.
        private func evaluatePinch(ratio: Float, at point: CGPoint) {
            pinchPoint = point
            status.pinchPoint = point
            status.pinchProgress = min(max((pinchOpenRatio - ratio) / (pinchOpenRatio - pinchCloseRatio), 0), 1)

            if !pinchClosed, ratio < pinchOpenRatio {
                pinchHaptics?.prepare() // warm the Taptic Engine before the grab is confirmed
            }

            if !pinchClosed, ratio < pinchCloseRatio {
                pinchClosed = true
                attemptGrab(at: point)
            } else if pinchClosed, ratio > pinchOpenRatio {
                pinchClosed = false
                releaseHeld()
            }
        }

        /// Picks the nearest snail to the pinch point by projected screen position, not a hit
        /// test (needs collision shapes, wrong node in the hierarchy). No-op if already holding.
        private func attemptGrab(at point: CGPoint) {
            guard held == nil, let arView, let cameraTransform = arView.session.currentFrame?.camera.transform
            else { return }
            let cameraPosition = cameraTransform.columns.3

            let nearest = snails
                .compactMap { snail -> (Entity, CGFloat)? in
                    guard let projected = arView.project(snail.position(relativeTo: nil)) else { return nil }
                    return (snail, hypot(projected.x - point.x, projected.y - point.y))
                }
                .filter { $0.1 < pinchPickRadius }
                .min { $0.1 < $1.1 }

            guard let (snail, _) = nearest else { return }
            let depth = simd_distance(SIMD3(cameraPosition.x, cameraPosition.y, cameraPosition.z),
                                       snail.position(relativeTo: nil))
            held = (snail, depth)
            pinchHaptics?.impactOccurred()
        }

        /// Moves the held snail to the last pinch point every rendered frame — same idiom as
        /// `hold(_:)`. Depth stays fixed from grab time, so it tracks the screen at constant depth.
        private func updateHeldSnail() {
            guard let (entity, depth) = held, let point = pinchPoint,
                  let arView, let ray = arView.ray(through: point)
            else { return }
            entity.setPosition(ray.origin + ray.direction * depth, relativeTo: nil)
        }

        /// Lets go of the held snail — moves it into `fading`; it never returns to `snails`.
        private func releaseHeld() {
            guard let (entity, _) = held else { return }
            held = nil
            fading.append((entity, 1))
            pinchHaptics?.impactOccurred(intensity: 0.4) // softer than the grab: this end is expected
        }

        /// Steps every fading snail's opacity down and removes it at zero. Manual, not
        /// `AnimationResource` — reuses this loop instead of a second animation subscription.
        private func updateFadingSnails() {
            for index in fading.indices.reversed() {
                fading[index].opacity -= pinchFadeStep
                if fading[index].opacity <= 0 {
                    fading[index].entity.removeFromParent()
                    fading.remove(at: index)
                } else {
                    fading[index].entity.components.set(OpacityComponent(opacity: fading[index].opacity))
                }
            }
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
                        snails.append(contentsOf: collectSnails(in: model))
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

        /// Finds every entity named `SeaSnail*` in a loaded model — the ones pinch pickup responds
        /// to. `Coral` and everything else just doesn't match the prefix.
        private func collectSnails(in entity: Entity) -> [Entity] {
            var found = entity.name.hasPrefix("SeaSnail") ? [entity] : []
            for child in entity.children {
                found.append(contentsOf: collectSnails(in: child))
            }
            return found
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
