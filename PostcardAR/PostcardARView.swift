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
import CoreVideo
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
/// Vision inference competes with ARKit tracking and RealityKit's render for the same GPU/ANE
/// time; 15 Hz keeps that contention low enough that the card model itself stays smooth. A
/// 30 Hz trial made the crosshair steadier but made the card jittery and prone to disappearing —
/// not a trade worth making.
private let handPoseSampleInterval: TimeInterval = 1.0 / 15.0

/// One Euro filter tuning for the displayed pinch point — see `OneEuroFilter` and "Filtering:
/// One Euro, not a fixed EMA" in `docs/interaction.md`. A fixed-factor EMA (tried first) is one
/// point on a jitter-vs-lag dial with no way off it: steady enough at rest cost ~124 ms of lag
/// while dragging, because the same factor damps a still hand and a fast one identically. One
/// Euro's cutoff rises with the point's own filtered speed, so it stays just as steady at rest
/// and opens up automatically once the hand is actually moving.
///
/// `pinchMinCutoff` sets the at-rest jitter floor in Hz — lower is steadier when still. This is
/// the knob for rest-jitter, not `pinchDerivativeCutoff` below (a lower value was tried there
/// instead and made jitter worse, not better — see its doc comment).
/// `pinchBeta` sets how fast the cutoff rises with speed — higher cuts lag faster once moving,
/// at the cost of jitter creeping back in sooner as speed picks up. `pinchBeta` is the filter's
/// own reference-implementation value (Casiez et al. 2012, https://cristal.univ-lille.fr/~casiez/1euro/);
/// `pinchMinCutoff` has been lowered from that reference default (1.0) for a steadier rest state.
private let pinchMinCutoff: Double = 0.5
private let pinchBeta: Double = 0.007

/// See `OneEuroFilter.derivativeCutoff`. A *lower* value than the reference implementation's
/// 1 Hz default was tried here first, on the theory that it would filter tremor out of the
/// derivative estimate before it could nudge the adaptive cutoff up. It made jitter worse: a
/// lower cutoff means a *laggier* derivative estimate, not a calmer one — after any fast motion
/// it decays back toward zero slowly, so the adaptive cutoff (and the point's responsiveness)
/// stays elevated for a stretch *after* the hand has actually stopped, reading as persistent
/// jitter rather than settling. Left at the reference default; `pinchMinCutoff` is the real knob
/// for rest-state steadiness.
private let pinchDerivativeCutoff: Double = 1.0

/// Thumb-to-index distance (normalized by hand size) marking closed/open. Two thresholds, not
/// one, to avoid chatter right at the pinch boundary.
private let pinchCloseRatio: Float = 0.12
private let pinchOpenRatio: Float = 0.2

/// Joint confidence floor — below this a hand-pose point is noise, not signal.
private let jointConfidenceMinimum: Float = 0.3

/// Confidence floor for `wrist`/`indexMCP` specifically — looser than `jointConfidenceMinimum`.
/// They only measure a coarse hand-size reference for `ratio`'s denominator, never a precise
/// position, and they run less confidently than the fingertips at close range (the wrist
/// especially, being nearer the frame edge). Gating them at the fingertip-precision bar meant
/// `ratio` — and with it the ring and release — silently stopped updating on close-range dips
/// that the fingertip-driven point itself sailed through untouched: ring stuck, snail never
/// releasing, looking frozen while the crosshair kept moving.
private let handScaleJointConfidenceMinimum: Float = 0.1

/// How close, in points, the pinch point must land to a snail's projected position to grab it.
private let pinchPickRadius: CGFloat = 80

/// Per-frame opacity step for a released snail — ~0.4 s fade at ~60 fps.
private let pinchFadeStep: Float = 1.0 / 24.0

/// If something's held and Vision loses the hand for this long, force a release — otherwise a
/// hand that lifts out of frame mid-grab never produces the "opened" sample to let go with.
private let handPoseLossTimeout: TimeInterval = 0.3

/// Consecutive open-ratio samples required before a release is confirmed — a single sample past
/// `pinchOpenRatio` is as likely to be one occluded joint (the thumb tip, mid-pinch) as a real
/// open, and a false release is unrecoverable (the snail is already fading). ~133 ms at
/// `handPoseSampleInterval`, comfortably under `handPoseLossTimeout` so a deliberate open
/// still beats a hand leaving frame. A counter, not a timer, so a slow inference sample (task
/// overlap skips a sample) can't make the very next sample look like a sustained open.
///
/// Was 3 (~200 ms). A fast "let go" flick motion-blurs the fingertips for a stretch — Vision's
/// confidence on them dips mid-motion the same way it does on a fast-moving card, nothing
/// broken about it — so most of a fast release's samples fail the point guard outright (skipped,
/// not counted) rather than reading a clean open. By the time the hand slows enough for
/// confidence to return, 3 *consecutive* clean reads asked for more settling than a fast
/// gesture naturally gives it; a slow release never hit this because there's no blur to dodge.
private let pinchOpenConfirmSamples = 2

/// Rotation needed to bring the **rear** camera's `capturedImage` upright for a given UI
/// orientation, so it can be handed to Vision as an explicit orientation hint. (The front
/// camera would additionally need mirroring; `ARWorldTrackingConfiguration` always uses the
/// rear one.) See "Reading the pinch" in `docs/interaction.md`.
private extension CGImagePropertyOrientation {
    init(rearCameraFor interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portraitUpsideDown: self = .left
        case .landscapeLeft: self = .down
        case .landscapeRight: self = .up
        default: self = .right // .portrait and .unknown
        }
    }
}

/// One Euro filter (Casiez, Roussel, Vogel 2012) — a low-pass whose cutoff frequency rises with
/// the signal's own filtered speed, so it damps tremor in a still signal as hard as a fixed-low
/// cutoff would, but opens up automatically once the signal is actually moving, instead of
/// damping every speed by the same fixed amount. See `pinchMinCutoff`/`pinchBeta`.
///
/// One instance per scalar channel — `PinchPointFilter` below runs two of these, one per axis,
/// rather than this filtering a `CGPoint` directly, since the two axes' speeds are logically
/// independent (a diagonal drag isn't "faster" in a way that should smooth differently from an
/// axis-aligned one of the same per-axis speed).
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    /// Cutoff for smoothing the *derivative* — 1 Hz in the reference implementation, which
    /// assumes a signal sampled well above 15 Hz. At `handPoseSampleInterval`'s rate, tremor in
    /// the raw point still shows up as noise in the derivative *after* 1 Hz smoothing, which then
    /// nudges `cutoff` (`minCutoff + beta * |derivative|`) up on a still hand exactly when
    /// `minCutoff` alone was supposed to hold it steady — the adaptive part fighting the at-rest
    /// part. Lower than the reference default here, unlike `minCutoff`/`beta`, precisely because
    /// this app's sample rate isn't what the default was chosen for.
    var derivativeCutoff: Double

    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var previousTimestamp: TimeInterval?

    // Written explicitly, not left to the synthesized memberwise init: a struct's synthesized
    // init is `private` as soon as *any* stored property is (the `previous*` ones above), even
    // ones excluded from it by having a default — not just the ones it actually takes as
    // parameters.
    init(minCutoff: Double, beta: Double, derivativeCutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: Double, timestamp: TimeInterval) -> Double {
        guard let previousValue, let previousTimestamp else {
            self.previousValue = value
            self.previousTimestamp = timestamp
            return value
        }
        let dt = max(timestamp - previousTimestamp, 1e-6) // guards divide-by-zero on a repeat timestamp

        let derivative = (value - previousValue) / dt
        let smoothedDerivative = lowPass(derivative, previous: previousDerivative,
                                          alpha: alpha(for: derivativeCutoff, dt: dt))

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let filtered = lowPass(value, previous: previousValue, alpha: alpha(for: cutoff, dt: dt))

        self.previousValue = filtered
        self.previousDerivative = smoothedDerivative
        self.previousTimestamp = timestamp
        return filtered
    }

    private func alpha(for cutoff: Double, dt: TimeInterval) -> Double {
        let timeConstant = 1 / (2 * .pi * cutoff)
        return 1 / (1 + timeConstant / dt)
    }

    private func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}

/// Two independent `OneEuroFilter`s over a `CGPoint` — see `OneEuroFilter` for why per-axis.
struct PinchPointFilter {
    private var x = OneEuroFilter(minCutoff: pinchMinCutoff, beta: pinchBeta, derivativeCutoff: pinchDerivativeCutoff)
    private var y = OneEuroFilter(minCutoff: pinchMinCutoff, beta: pinchBeta, derivativeCutoff: pinchDerivativeCutoff)

    mutating func filter(_ point: CGPoint, timestamp: TimeInterval) -> CGPoint {
        CGPoint(x: x.filter(point.x, timestamp: timestamp),
                y: y.filter(point.y, timestamp: timestamp))
    }
}

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

    /// TEMPORARY — pinch-point diagnostics, to be read off a screenshot and then deleted. Not
    /// a permanent status field like the others above.
    var pinchDebug: String = ""
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

        /// Consecutive samples in a row read past `pinchOpenRatio` while held — see
        /// `pinchOpenConfirmSamples`. Reset on any sample that isn't one.
        private var pinchOpenStreak = 0

        /// Last time a sample saw a hand at all — what `handPoseLossTimeout` counts against. Not
        /// "read four confident joints": a tight pinch is exactly when the thumb occludes the
        /// index fingertip, so requiring joint confidence here would call the most deliberate
        /// pinch a lost hand.
        private var lastHandSeenTime = Date.distantPast

        /// Displayed pinch point — crosshair and drag both read this, set from each raw sample
        /// after `pinchPointFilter` damps it. No render-loop glide stage: one was tried, and
        /// gliding toward a target that itself only moves at `handPoseSampleInterval` (15 Hz)
        /// compounds into steady-state lag behind the hand, which reads worse than the
        /// sample-to-sample stair-step it was meant to fix.
        private var pinchPoint: CGPoint?

        /// One Euro filter state for `pinchPoint` — carries the previous value/derivative across
        /// samples, so it's reset (fresh `PinchPointFilter()`) whenever the hand is lost, the
        /// same "don't glide in from a stale position" reasoning `pinchPoint == nil` used to get
        /// for free by being nil itself.
        private var pinchPointFilter = PinchPointFilter()

        /// Ring fill from the last sample that actually computed a `ratio` — kept so a
        /// wrist/knuckle confidence dip (see `updatePinchDetection()`) can move the crosshair
        /// without also resetting its ring to empty.
        private var pinchProgress: Float = 0

        /// `.soft` — firm grab, gentle let-go. `prepare()`d early to hide Taptic spin-up latency.
        private var pinchHaptics: UIImpactFeedbackGenerator?

        /// Renders `PinchCrosshair` as a subview of `arView` itself, not a SwiftUI overlay above
        /// it. `pinchPoint` is computed in `arView.bounds` space and `arView.ray(through:)`
        /// consumes it in that same space — putting the crosshair through a *second* coordinate
        /// system (SwiftUI's overlay) was the actual bug: the same point projected right for the
        /// held snail and wrong for the crosshair, because only one of the two ever agreed with
        /// `arView.bounds`. A subview of `arView` can't disagree with it.
        private var crosshairHost: UIHostingController<PinchCrosshair>?

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
            setUpCrosshair(in: arView)

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

        /// Adds `PinchCrosshair` as a plain subview of `arView`, not a SwiftUI overlay — see
        /// `crosshairHost`. Sized once; `updateCrosshair(at:progress:)` only ever moves/hides it.
        private func setUpCrosshair(in arView: ARView) {
            let host = UIHostingController(rootView: PinchCrosshair(progress: 0))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            host.view.isHidden = true
            arView.addSubview(host.view)
            crosshairHost = host
        }

        /// Moves the crosshair to `point` (in `arView`'s own coordinate space — same as
        /// `pinchPoint`) and updates its ring fill. `nil` hides it.
        private func updateCrosshair(at point: CGPoint?, progress: Float) {
            guard let host = crosshairHost else { return }
            guard let point else {
                host.view.isHidden = true
                return
            }
            host.view.isHidden = false
            host.view.center = point
            host.rootView = PinchCrosshair(progress: progress)
        }

        /// Size of `capturedImage` after being rotated upright by `imageOrientation` — what the
        /// aspect-fill math in `updatePinchDetection()` measures the crop against. A 90°
        /// rotation swaps width and height; `capturedImage` itself is always landscape.
        private static func uprightImageSize(of pixelBuffer: CVPixelBuffer,
                                              orientation: CGImagePropertyOrientation) -> CGSize {
            let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            switch orientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return CGSize(width: height, height: width)
            default:
                return CGSize(width: width, height: height)
            }
        }

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
            let timestamp = frame.timestamp // feeds `pinchPointFilter`; ARKit's clock, not `Date()`
            let viewportSize = arView.bounds.size
            let interfaceOrientation = arView.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            // `capturedImage` is always landscape (sensor-native), regardless of device
            // orientation — this is the rotation needed to bring it upright for the current UI.
            let imageOrientation = CGImagePropertyOrientation(rearCameraFor: interfaceOrientation)
            let uprightImageSize = Self.uprightImageSize(of: pixelBuffer, orientation: imageOrientation)

            // @MainActor so mutations below land on the same thread `onRenderFrame` runs on;
            // `perform(on:orientation:)` still suspends off it for the actual inference.
            Task { @MainActor in
                defer { handPoseTaskInFlight = false }

                // Orientation hint given explicitly this time: Vision rotates internally and
                // hands back joints already in the upright image's coordinate space, which is
                // what the aspect-fill math below expects. `ARFrame.displayTransform` was tried
                // first for this same job and never lined up right against `ARView`'s own camera
                // background rendering — this mirrors the mapping a working reference
                // implementation (`posehandtest`) uses instead.
                let hand = try? await handPoseRequest.perform(on: pixelBuffer, orientation: imageOrientation).first
                if hand != nil {
                    lastHandSeenTime = Date()
                }

                // Truly no hand is the only case that wipes state — see "Occlusion vs. no hand"
                // in `docs/interaction.md`. Everything else (one tip occluded, wrist/knuckle
                // unreadable) is handled below without erasing anything, because a hand that's
                // merely hard to read this sample isn't a hand that's gone.
                guard let hand else {
                    pinchPoint = nil
                    pinchPointFilter = PinchPointFilter() // don't glide in from a stale position
                    pinchOpenStreak = 0
                    updateCrosshair(at: nil, progress: 0)
                    if pinchClosed, Date().timeIntervalSince(lastHandSeenTime) >= handPoseLossTimeout {
                        pinchClosed = false
                        releaseHeld()
                    }
                    return
                }

                // `ARView` renders its camera background aspect-fill: scaled up until it covers
                // the view, overflow cropped evenly off both sides. Reproducing that scale/crop
                // by hand — rather than trusting `displayTransform` to already match it — is
                // what actually lines the point up with what's on screen.
                //
                // The flip from Vision's convention to a normal top-left/y-down image is done by
                // `NormalizedPoint.toImageCoordinates`, not by hand: a hand-rolled `1 - y` was
                // never verified against this type's actual convention (it's a distinct type,
                // `Vision.NormalizedPoint`, not the plain `CGPoint` the old ObjC-bridged Vision
                // API returned) and is exactly the kind of small, silent, survives-every-later-fix
                // error a wrong assumption there would produce.
                func screenPoint(for location: NormalizedPoint) -> CGPoint {
                    guard uprightImageSize.width > 0, uprightImageSize.height > 0 else { return .zero }
                    let imagePoint = location.toImageCoordinates(uprightImageSize, origin: .upperLeft)
                    let scale = max(viewportSize.width / uprightImageSize.width,
                                     viewportSize.height / uprightImageSize.height)
                    let displayed = CGSize(width: uprightImageSize.width * scale,
                                            height: uprightImageSize.height * scale)
                    let originX = (viewportSize.width - displayed.width) / 2
                    let originY = (viewportSize.height - displayed.height) / 2
                    return CGPoint(x: originX + imagePoint.x * scale, y: originY + imagePoint.y * scale)
                }

                // Raw joints, kept regardless of confidence — `ratio` below falls back to these
                // once *a* confident tip has vouched for the sample, same as the point does.
                let thumbJoint = hand.joint(for: .thumbTip)
                let indexJoint = hand.joint(for: .indexTip)

                // Confident, not just present: a joint below `jointConfidenceMinimum` is noise,
                // not a position. `index` in particular sits on top of the joint the thumb
                // occludes mid-pinch, so during exactly the drag this gesture is for, it's the
                // one that routinely drops out.
                let thumb = thumbJoint.flatMap { $0.confidence > jointConfidenceMinimum ? $0 : nil }
                let index = indexJoint.flatMap { $0.confidence > jointConfidenceMinimum ? $0 : nil }

                // At least one tip, not both: requiring both dropped the *entire* sample — point
                // included — on a single occluded tip, freezing the point for a full sample
                // period (~67 ms) at exactly the moment (mid-drag, thumb over index) it happens
                // most. The point only needs *a* position; `ratio` is what actually needs both
                // tips' true distance, and stays gated on both, further down.
                guard let anchorTip = thumb ?? index else {
                    // Hand's here but neither tip is readable this sample. Hold the last point
                    // rather than erasing it — same dead-band idiom as the card pose filter, and
                    // the reasoning `docs/interaction.md` calls "Occlusion vs. no hand": a snail
                    // still `held` here needs `pinchPoint` left alone, not nulled, or it freezes
                    // mid-drag without ever actually being released.
                    if pinchClosed, Date().timeIntervalSince(lastHandSeenTime) >= handPoseLossTimeout {
                        pinchClosed = false
                        releaseHeld()
                    }
                    return
                }

                // Midpoint when both tips are readable — "between thumb and index," verified
                // correct against real device numbers, see `docs/interaction.md` — and just the
                // one confident tip's own position otherwise, rather than no update at all.
                let raw: CGPoint
                if let thumb, let index {
                    let thumbScreenPoint = screenPoint(for: thumb.location)
                    let indexScreenPoint = screenPoint(for: index.location)
                    raw = CGPoint(x: (thumbScreenPoint.x + indexScreenPoint.x) / 2,
                                   y: (thumbScreenPoint.y + indexScreenPoint.y) / 2)
                } else {
                    raw = screenPoint(for: anchorTip.location)
                }

                // TEMPORARY — see `ARStatus.pinchDebug`.
                status.pinchDebug = String(
                    format: "view %.0fx%.0f img %.0fx%.0f raw %.2f,%.2f pt %.0f,%.0f",
                    viewportSize.width, viewportSize.height,
                    uprightImageSize.width, uprightImageSize.height,
                    anchorTip.location.x, anchorTip.location.y,
                    raw.x, raw.y
                )

                let filtered = pinchPointFilter.filter(raw, timestamp: timestamp)

                // Point placed — move the crosshair unconditionally before checking whether
                // there's enough to also evaluate a grab/release this sample.
                pinchPoint = filtered
                updateCrosshair(at: filtered, progress: pinchProgress)

                // `ratio` uses `thumbJoint`/`indexJoint` — the *raw* joints, not the
                // confidence-filtered `thumb`/`index` — for the same reason the point fell back
                // to one confident tip earlier: requiring both confident here meant a fast
                // release (which blurs both tips at once more often than it blurs one) rarely
                // produced a usable ratio sample at all, so `pinchOpenConfirmSamples` rarely got
                // the consecutive reads it needed and the snail stayed `held`, looking like it
                // was floating rather than being dragged-but-never-released. `anchorTip` already
                // guarantees at least one tip is genuinely confident this sample — that's what
                // makes trusting the other tip's raw position acceptable here, same as it was for
                // the point. `wrist`/`indexMCP` stay gated on `handScaleJointConfidenceMinimum`.
                guard
                    let thumbJoint, let indexJoint,
                    let wrist = hand.joint(for: .wrist), wrist.confidence > handScaleJointConfidenceMinimum,
                    let knuckle = hand.joint(for: .indexMCP), knuckle.confidence > handScaleJointConfidenceMinimum
                else { return } // point already placed; nothing here needs a ratio this sample

                let handScale = wrist.distance(to: knuckle)
                guard handScale > 0 else { return }
                let ratio = Float(thumbJoint.distance(to: indexJoint) / handScale)

                evaluatePinch(ratio: ratio, at: filtered)
            }
        }

        /// Debounces one hand-pose sample into a grab or release, and updates the ring fill.
        /// The point itself (`pinchPoint`) is already set by the caller — see
        /// `updatePinchDetection()` — since placing it doesn't depend on anything evaluated here.
        private func evaluatePinch(ratio: Float, at point: CGPoint) {
            pinchProgress = min(max((pinchOpenRatio - ratio) / (pinchOpenRatio - pinchCloseRatio), 0), 1)
            updateCrosshair(at: point, progress: pinchProgress)

            if !pinchClosed, ratio < pinchOpenRatio {
                pinchHaptics?.prepare() // warm the Taptic Engine before the grab is confirmed
            }

            if !pinchClosed, ratio < pinchCloseRatio {
                pinchClosed = true
                pinchOpenStreak = 0
                attemptGrab(at: point)
            } else if pinchClosed, ratio > pinchOpenRatio {
                // Require a run of open samples, not just one — a single occluded joint (the
                // thumb tip, mid-pinch) can spike the ratio without the hand actually opening,
                // and a false release can't be undone: the snail is already fading by the time
                // the next sample would prove it wrong.
                pinchOpenStreak += 1
                if pinchOpenStreak >= pinchOpenConfirmSamples {
                    pinchClosed = false
                    pinchOpenStreak = 0
                    releaseHeld()
                }
            } else {
                pinchOpenStreak = 0
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
