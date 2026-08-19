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

/// A reference image whose name starts with this is a *Simulation* card and runs a minigame;
/// every other card is a *Showcase* card that only stands its model up to be looked at. See
/// `CardKind` for what the two actually do differently.
///
/// The type travels in the name for the same reason the model does: adding a card stays two
/// files and no code change, and nothing here names an individual card. Same idiom as the
/// `SeaSnail` prefix in `collectSnails(in:)`.
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

/// Hand-pose sampling rate, deliberately slower than the render loop — see `updatePinchDetection()`.
/// Vision inference competes with ARKit and RealityKit for the same GPU/ANE time; 30 Hz made the
/// crosshair steadier but the card jittery, not a trade worth making.
private let handPoseSampleInterval: TimeInterval = 1.0 / 15.0

/// One Euro filter tuning for the displayed pinch point — see `OneEuroFilter` and
/// `docs/interaction.md`. `pinchMinCutoff` (Hz) is the at-rest jitter floor, the knob to reach
/// for over `pinchDerivativeCutoff` below. `pinchBeta` is how fast the cutoff rises with speed;
/// left at the reference implementation's value (Casiez et al. 2012).
private let pinchMinCutoff: Double = 0.5
private let pinchBeta: Double = 0.007

/// See `OneEuroFilter.derivativeCutoff`. Left at the reference default (1 Hz) — a lower value
/// makes the derivative laggier, not calmer, keeping the adaptive cutoff elevated *longer* after
/// real motion. `pinchMinCutoff` is the actual rest-state knob.
private let pinchDerivativeCutoff: Double = 1.0

/// Thumb-to-index distance (normalized by hand size) marking closed/open. Two thresholds, not
/// one, to avoid chatter right at the pinch boundary.
private let pinchCloseRatio: Float = 0.12
private let pinchOpenRatio: Float = 0.2

/// Joint confidence floor — below this a hand-pose point is noise, not signal.
private let jointConfidenceMinimum: Float = 0.3

/// Confidence floor for `wrist`/`indexMCP` specifically — looser than `jointConfidenceMinimum`,
/// since they only measure a coarse hand-size reference for `ratio`'s denominator, and read less
/// confidently than the fingertips at close range (the wrist especially, being nearer the frame
/// edge).
private let handScaleJointConfidenceMinimum: Float = 0.1

/// How close, in points, the pinch point must land to a snail's projected position to grab it.
private let pinchPickRadius: CGFloat = 80

/// Per-frame opacity step for a released snail — ~0.4 s fade at ~60 fps.
private let pinchFadeStep: Float = 1.0 / 24.0

/// How close, in metres, a released snail must be to its home slot to snap back — put down,
/// not collected — instead of fading away scored. Roughly a fifth of a model's authored width
/// (`modelWidthRelativeToCard`) — close enough that "let go right on the coral" reads as
/// intentional, far enough that a light release mid-drag doesn't feel sticky.
private let pinchSnapRadius: Float = 0.04

/// How long the snap-back glide takes, via `Entity.move(to:relativeTo:duration:)`.
private let pinchSnapDuration: TimeInterval = 0.2

/// If something's held and Vision loses the hand for this long, force a release — otherwise a
/// hand that lifts out of frame mid-grab never produces the "opened" sample to let go with.
private let handPoseLossTimeout: TimeInterval = 0.3

/// Consecutive open-ratio samples required before a release is confirmed — one sample past
/// `pinchOpenRatio` is as likely to be an occluded joint as a real open, and a false release is
/// unrecoverable. ~133 ms at `handPoseSampleInterval`, under `handPoseLossTimeout`.
private let pinchOpenConfirmSamples = 2

/// Rotation to bring the **rear** camera's `capturedImage` upright, for Vision's orientation
/// hint. (`ARWorldTrackingConfiguration` always uses the rear camera, no mirroring needed.)
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
/// the signal's own filtered speed, so it damps tremor at rest as hard as a fixed-low cutoff
/// would, but opens up automatically once the signal is actually moving. See
/// `pinchMinCutoff`/`pinchBeta`.
///
/// One instance per scalar channel — `PinchPointFilter` below runs two, one per axis, since the
/// axes' speeds are logically independent.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    /// Cutoff for smoothing the *derivative* before it's allowed to push the main `cutoff` up —
    /// see `pinchDerivativeCutoff`'s doc comment for why it stays at the reference default.
    var derivativeCutoff: Double

    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var previousTimestamp: TimeInterval?

    // Explicit init: the synthesized memberwise one goes `private` once any stored property does
    // (the `previous*` ones above), even ones it doesn't take as parameters.
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
/// Whole-observation confidence for "there is a hand in frame", used by the occlusion lock and
/// nothing else. Deliberately low, and deliberately not `jointConfidenceMinimum`: reading a pinch
/// needs four specific joints resolved, whereas locking only needs to know a hand is there — and
/// the hand covering a card is exactly the pose those four joints are hardest to read from.
private let handPresenceConfidence: Float = 0.1

/// How long after the last hand sighting a hand still counts as being in frame. Longer than
/// `handPoseLossTimeout` on purpose: this one keeps a model locked in place, and a model blinking
/// out on a dropped sample or two is far more noticeable than a late release.
private let handPresenceTimeout: TimeInterval = 1.0

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

        /// `game.phase` as of the previous frame. The instruction and result screens change the
        /// phase from SwiftUI, and this is how the coordinator notices that a fresh run needs its
        /// picked-off snails put back.
        private var lastGamePhase: GameSession.Phase = .idle

        /// One per reference image, built in `start(in:)` and never added to afterwards.
        private var cards: [Card] = []

        /// Dropping this cancels the render-loop subscription, so it has to be held.
        private var frameSubscription: (any Cancellable)?

        /// For projecting/raycasting and reading `session.currentFrame` in the pinch code below.
        private weak var arView: ARView?

        /// One grabbable drupella snail.
        private struct Snail {
            let entity: Entity

            /// Its local transform when the model loaded, so Play Again can put it back on the
            /// coral. A released snail is hidden rather than deleted precisely so this works.
            let home: Transform

            /// Already picked off. Not grabbable, and hidden once its fade finishes.
            var removed = false
        }

        /// Every `SeaSnail*` entity across every loaded *simulation* model, flattened. Showcase
        /// models are never collected, which is the whole of "no pinch on a showcase card".
        private var snails: [Snail] = []

        /// The snail being dragged — its index into `snails` (so release can reach its `home`
        /// and flip `removed`) — and the camera distance it was grabbed at (held constant for
        /// the drag). `nil` also gates pickup to one at a time.
        private var held: (index: Int, depth: Float)?

        /// Released snails, fading toward `opacity == 0` before being hidden.
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

        /// Last time `evaluatePinch(ratio:at:)` actually ran — what `handPoseLossTimeout` counts
        /// against for the *two* forced-release bail-outs that lack any other evidence the hand
        /// is still there (no hand at all; neither tip readable). Not "last time a sample saw a
        /// hand" — that made the timeout dead code, since those bail-outs always run right after
        /// a hand was seen. The third guard (wrist/knuckle) doesn't use this — see its comment.
        private var lastPinchEvaluationTime = Date.distantPast

        /// Displayed pinch point — crosshair and drag both read this, set from each raw sample
        /// after `pinchPointFilter` damps it. No render-loop glide stage: gliding toward a target
        /// that itself only moves at `handPoseSampleInterval` (15 Hz) reads as steady-state lag.
        private var pinchPoint: CGPoint?

        /// Last sample that saw a hand at all, however poorly resolved — what the occlusion lock
        /// counts against. A hand covering a card reads well enough here and badly above, so this
        /// is gated on the loose `handPresenceConfidence`, not `jointConfidenceMinimum`.
        private var lastHandSeenTime = Date.distantPast

        /// One Euro filter state for `pinchPoint` — reset (fresh `PinchPointFilter()`) whenever
        /// the hand is lost, so re-acquiring doesn't glide in from a stale position/derivative.
        private var pinchPointFilter = PinchPointFilter()

        /// Ring fill from the last sample that actually computed a `ratio` — kept so a
        /// wrist/knuckle confidence dip can move the crosshair without resetting its ring.
        private var pinchProgress: Float = 0

        /// `.soft` — firm grab, gentle let-go. `prepare()`d early to hide Taptic spin-up latency.
        private var pinchHaptics: UIImpactFeedbackGenerator?

        /// Fires once, on a snap-back release — a different generator, not another `.impact`
        /// intensity, so "put back, not collected" reads as its own kind of event rather than a
        /// third shade of grab/release.
        private var snapHaptics: UINotificationFeedbackGenerator?

        /// `PinchCrosshair` hosted as a plain subview of `arView`, not a SwiftUI overlay — shares
        /// `arView.bounds`' coordinate space by construction, the same space `pinchPoint` and
        /// `arView.ray(through:)` use.
        private var crosshairHost: UIHostingController<PinchCrosshair>?

        init(status: ARStatus, game: GameSession) {
            self.status = status
            self.game = game
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

            self.arView = arView
            pinchHaptics = UIImpactFeedbackGenerator(style: .soft, view: arView)
            snapHaptics = UINotificationFeedbackGenerator(view: arView)
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
            // as a hand regardless of what Vision managed to read on the last sample.
            let handInFrame = held != nil
                || Date().timeIntervalSince(lastHandSeenTime) < handPresenceTimeout
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
            updatePinchDetection()
            updateHeldSnail()
            updateFadingSnails()
        }

        // MARK: The run

        /// Drives the `GameSession` from what the camera can see, and applies the two things a
        /// phase change means to the scene: a fresh run needs its snails back, and nothing is
        /// grabbable outside a live run.
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

            // Both entry points into a fresh run, spotted here rather than in the buttons because
            // the buttons live in SwiftUI and the entities live here. Resuming out of `.grace`
            // also lands in `.countdown` or `.playing` and must *not* restore — that run is the
            // same run, snails and all — which is why these test where the phase came from.
            if (game.phase == .instructions && lastGamePhase != .instructions)
                || (game.phase == .countdown && lastGamePhase == .finished) {
                restoreSnails()
            }
            lastGamePhase = game.phase

            // A snail still in hand when the run stops — buzzer, or the card walking out of frame
            // — is dropped rather than carried into whatever comes next.
            if game.phase != .playing, held != nil {
                releaseHeld()
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
        /// `pinchPoint`) and updates its ring fill. `nil`, or the run not being `.playing`,
        /// hides it — it means "this is where the pinch lands", which is a lie on every other
        /// screen (including a live run's own instructions/countdown/grace/result phases).
        private func updateCrosshair(at point: CGPoint?, progress: Float) {
            guard let host = crosshairHost else { return }
            guard let point, game.phase == .playing else {
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

                // Explicit orientation hint: Vision rotates internally and hands back joints
                // already in the upright image's coordinate space, which the aspect-fill math
                // below expects.
                let hand = try? await handPoseRequest.perform(on: pixelBuffer, orientation: imageOrientation).first

                // Presence is a far looser question than pinching, and has to be asked first. A
                // hand held flat over a card — the case the occlusion lock exists for — is
                // usually a palm filling the frame with the wrist cropped off and the knuckles
                // hidden behind the fingers: Vision still returns the hand, but the pinch-specific
                // joints below do not all clear their threshold. Gating presence on those joints
                // meant the lock never engaged in exactly the situation it was written for.
                if let hand, hand.confidence > handPresenceConfidence {
                    lastHandSeenTime = Date()
                }

                // Truly no hand is the only case that wipes state — see "Occlusion vs. no hand"
                // in `docs/interaction.md`. A hand that's merely hard to read this sample isn't a
                // hand that's gone.
                guard let hand else {
                    pinchPoint = nil
                    pinchPointFilter = PinchPointFilter() // don't glide in from a stale position
                    pinchOpenStreak = 0
                    updateCrosshair(at: nil, progress: 0)
                    if pinchClosed, Date().timeIntervalSince(lastPinchEvaluationTime) >= handPoseLossTimeout {
                        pinchClosed = false
                        releaseHeld()
                    }
                    return
                }

                // `ARView` renders its camera background aspect-fill: scaled up until it covers
                // the view, overflow cropped evenly off both sides. Reproducing that scale/crop
                // by hand is what lines the point up with what's on screen — see "The point" in
                // `docs/interaction.md`.
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
                // not a position. `index` sits on top of the joint the thumb occludes mid-pinch,
                // so it's the one that routinely drops out during exactly the drag this is for.
                let thumb = thumbJoint.flatMap { $0.confidence > jointConfidenceMinimum ? $0 : nil }
                let index = indexJoint.flatMap { $0.confidence > jointConfidenceMinimum ? $0 : nil }

                // At least one tip, not both — requiring both froze the point on every single
                // occluded tip. `ratio` is what actually needs both tips' distance, further down.
                guard let anchorTip = thumb ?? index else {
                    // Neither tip readable this sample. Hold the last point rather than erasing
                    // it — same dead-band idiom as the card pose filter.
                    if pinchClosed, Date().timeIntervalSince(lastPinchEvaluationTime) >= handPoseLossTimeout {
                        pinchClosed = false
                        releaseHeld()
                    }
                    return
                }

                // Midpoint when both tips are readable, one confident tip's own position
                // otherwise — see "The point" in `docs/interaction.md`.
                let raw: CGPoint
                if let thumb, let index {
                    let thumbScreenPoint = screenPoint(for: thumb.location)
                    let indexScreenPoint = screenPoint(for: index.location)
                    raw = CGPoint(x: (thumbScreenPoint.x + indexScreenPoint.x) / 2,
                                   y: (thumbScreenPoint.y + indexScreenPoint.y) / 2)
                } else {
                    raw = screenPoint(for: anchorTip.location)
                }

                let filtered = pinchPointFilter.filter(raw, timestamp: timestamp)

                // Point placed — move the crosshair unconditionally before checking whether
                // there's enough to also evaluate a grab/release this sample.
                pinchPoint = filtered
                updateCrosshair(at: filtered, progress: pinchProgress)

                // `ratio` trusts the *raw* joints, not confidence-filtered `thumb`/`index` —
                // `anchorTip` already guarantees one tip is genuinely confident this sample,
                // which is enough to trust the other tip's raw position too. Requiring both
                // confident made a fast release (blurs both tips) rarely produce a usable sample.
                guard
                    let thumbJoint, let indexJoint,
                    let wrist = hand.joint(for: .wrist), wrist.confidence > handScaleJointConfidenceMinimum,
                    let knuckle = hand.joint(for: .indexMCP), knuckle.confidence > handScaleJointConfidenceMinimum
                // No forced-release fallback here, unlike the guards above: this one fails
                // routinely during a genuine grip (close-range wrist confidence), so a timeout
                // keyed to it fired mid-drag — tried, caused release-then-regrab looping. The
                // point above still tracking is itself evidence the hand hasn't gone anywhere.
                else { return }

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
            lastPinchEvaluationTime = Date() // this sample is what the forced-release bail-outs were waiting for
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
                // A run of open samples, not just one — an occluded joint can spike the ratio
                // without the hand opening, and a false release can't be undone.
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
            // Only during a live run. Instructions, countdown, grace and the result screen all
            // leave the model on camera, and pinching through any of them would score.
            guard game.phase == .playing, held == nil, let arView,
                  let cameraTransform = arView.session.currentFrame?.camera.transform
            else { return }
            let cameraPosition = cameraTransform.columns.3

            let nearest = snails.indices
                .compactMap { index -> (Int, CGFloat)? in
                    // A snail already picked off, or on a card that is not on screen, is not
                    // there to grab.
                    guard !snails[index].removed, snails[index].entity.isEnabledInHierarchy,
                          let projected = arView.project(snails[index].entity.position(relativeTo: nil))
                    else { return nil }
                    return (index, hypot(projected.x - point.x, projected.y - point.y))
                }
                .filter { $0.1 < pinchPickRadius }
                .min { $0.1 < $1.1 }

            guard let (index, _) = nearest else { return }
            let snail = snails[index].entity
            let depth = simd_distance(SIMD3(cameraPosition.x, cameraPosition.y, cameraPosition.z),
                                       snail.position(relativeTo: nil))
            snails[index].removed = true
            held = (index, depth)
            // Scored at the grab, not the release: a grabbed snail always ends up removed, so
            // this is the moment it is committed — and the moment the player feels the haptic.
            // `releaseHeld()` can still undo both if it turns out to be a snap-back, not a pick.
            game.scored()
            pinchHaptics?.impactOccurred()
        }

        /// Moves the held snail to the last pinch point every rendered frame — same idiom as
        /// `hold(_:)`. Depth stays fixed from grab time, so it tracks the screen at constant depth.
        private func updateHeldSnail() {
            guard let (index, depth) = held, let point = pinchPoint,
                  let arView, let ray = arView.ray(through: point)
            else { return }
            snails[index].entity.setPosition(ray.origin + ray.direction * depth, relativeTo: nil)
        }

        /// Lets go of the held snail. Close enough to its home slot, and the run hasn't ended out
        /// from under it, reads as "put back" rather than "collected": it glides home via
        /// RealityKit's own move animation, un-scores, and clears `removed` — same conditions
        /// `attemptGrab(at:)` requires for a *grab*, so an undo can't outlive the run any more
        /// than a pick can start after it. Otherwise it moves into `fading` as before, staying
        /// `removed` and keeping the point until `restoreSnails()` puts it back for the next run.
        private func releaseHeld() {
            guard let (index, _) = held else { return }
            held = nil
            let entity = snails[index].entity

            var snapping = false
            if game.phase == .playing, let parent = entity.parent {
                let home = parent.convert(position: snails[index].home.translation, to: nil)
                snapping = simd_distance(home, entity.position(relativeTo: nil)) < pinchSnapRadius
            }

            if snapping {
                entity.move(to: snails[index].home, relativeTo: entity.parent, duration: pinchSnapDuration)
                snails[index].removed = false
                game.unscored()
                snapHaptics?.notificationOccurred(.success)
            } else {
                fading.append((entity, 1))
                pinchHaptics?.impactOccurred(intensity: 0.4) // softer than the grab: this end is expected
            }
        }

        /// Steps every fading snail's opacity down and hides it at zero. Manual, not
        /// `AnimationResource` — reuses this loop instead of a second animation subscription.
        ///
        /// Hidden rather than `removeFromParent()`: Play Again needs the same snails back on the
        /// same coral, and keeping them in the tree makes that a transform reset instead of a
        /// second load of a model already in memory. See `restoreSnails()`.
        private func updateFadingSnails() {
            for index in fading.indices.reversed() {
                fading[index].opacity -= pinchFadeStep
                if fading[index].opacity <= 0 {
                    fading[index].entity.isEnabled = false
                    fading.remove(at: index)
                } else {
                    fading[index].entity.components.set(OpacityComponent(opacity: fading[index].opacity))
                }
            }
        }

        /// Puts every picked-off snail back where its model loaded, ready for another run.
        ///
        /// `home` is a *local* transform, so restoring it re-seats the snail on the coral wherever
        /// the coral currently is — dragging writes world-space positions into that same local
        /// transform, which is exactly what this undoes.
        private func restoreSnails() {
            held = nil
            fading.removeAll()
            for index in snails.indices {
                let entity = snails[index].entity
                entity.transform = snails[index].home
                entity.components.remove(OpacityComponent.self)
                entity.isEnabled = true
                snails[index].removed = false
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
                        // Showcase models are looked at, not touched, so their snails never enter
                        // the grabbable pool — `attemptGrab(at:)` has nothing to find on one.
                        if card.kind == .simulation {
                            snails.append(contentsOf: collectSnails(in: model).map {
                                Snail(entity: $0, home: $0.transform)
                            })
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
