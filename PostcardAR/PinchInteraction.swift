//
//  PinchInteraction.swift
//  PostcardAR
//
//  The one gesture: pinch to grab a `Drupella*` entity, drag it, let go. Vision reads the same
//  camera frame ARKit is already tracking cards against, independently and at its own pace — see
//  docs/interaction.md for the full mechanism.
//
//  `PostcardARView.Coordinator` owns one `PinchInteraction` and talks to it through five calls:
//  `attach(to:)` once at start, `collectSnails(from:)` once per loaded simulation model,
//  `update()` once a rendered frame, and `handInFrame` read once a rendered frame for the
//  occlusion lock. Nothing here reaches back into the coordinator except through `game`.
//

import ARKit
import CoreVideo
import RealityKit
import UIKit
import Vision

// MARK: - Tuning

/// Hand-pose sampling rate, deliberately slower than the render loop — see `PinchInteraction.sample()`.
/// Vision inference competes with ARKit and RealityKit for the same GPU/ANE time; 30 Hz made the
/// pinch point steadier but the card jittery, not a trade worth making.
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
/// not collected — instead of fading away scored. Roughly a fifth of the coral model's target
/// width (`modelWidths` in `PostcardARView.swift`) — close enough that "let go right on the
/// coral" reads as intentional, far enough that a light release mid-drag doesn't feel sticky.
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

/// Prefix marking a grabbable snail entity — see `collectSnails(from:)`.
private let drupellaPrefix = "Drupella"

/// Suffix marking a snail's separate outline mesh. Shipped as a flat sibling of its snail in the
/// source asset, not a child; `collectSnails(from:)` matches it to strip it out of the grabbable
/// pool and re-parent it under its snail instead.
private let outlineSuffix = "_Outline"

/// Whole-observation confidence for "there is a hand in frame", used by the occlusion lock and
/// nothing else. Deliberately low, and deliberately not `jointConfidenceMinimum`: reading a pinch
/// needs four specific joints resolved, whereas locking only needs to know a hand is there — and
/// the hand covering a card is exactly the pose those four joints are hardest to read from.
private let handPresenceConfidence: Float = 0.1

/// How long after the last hand sighting a hand still counts as being in frame. Longer than
/// `handPoseLossTimeout` on purpose: this one keeps a model locked in place, and a model blinking
/// out on a dropped sample or two is far more noticeable than a late release.
private let handPresenceTimeout: TimeInterval = 1.0

/// A hand counts as too close once one finger segment — knuckle to knuckle, or knuckle to tip —
/// covers this fraction of the viewport's width. See `PinchInteraction.handTooClose`.
///
/// Lands around 18 cm from the lens on a portrait iPhone: a proximal phalanx is roughly 4.5 cm,
/// and the aspect-fill crop leaves about 44° of horizontal field of view on screen, so the visible
/// frame is some 15 cm across at that distance. **Lower** it to warn from further away.
private let handTooCloseSegmentFraction: CGFloat = 0.30

/// Consecutive too-close samples before the warning appears — a third of a second at
/// `handPoseSampleInterval`. There is deliberately no matching delay on the way out: one sample
/// that is not too close clears it immediately, so the warning cannot outlive its cause.
private let handTooCloseConfirmSamples = 5

/// Adjacent joints along each finger, tip inward. Only *neighbouring* pairs are ever measured, and
/// the wrist is deliberately absent: it is the first thing to leave the frame as a hand approaches
/// the lens, which is precisely when this measurement has to keep working.
private let fingerJointChains: [[HumanHandPoseObservation.JointName]] = [
    [.thumbTip, .thumbIP, .thumbMP],
    [.indexTip, .indexDIP, .indexPIP, .indexMCP],
    [.middleTip, .middleDIP, .middlePIP, .middleMCP],
    [.ringTip, .ringDIP, .ringPIP, .ringMCP],
    [.littleTip, .littleDIP, .littlePIP, .littleMCP],
]

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

// MARK: - PinchInteraction

/// Owns everything pinch pickup touches: the grabbable snails, the drag/release state, hand-pose
/// sampling, and the haptics. `PostcardARView.Coordinator` holds one and drives it
/// per frame; see the file header for the full call surface.
final class PinchInteraction {
    /// One grabbable drupella snail.
    private struct Snail {
        let entity: Entity

        /// Its local transform when the model loaded, so Play Again — and a snap-back release —
        /// can put it back on the coral. A released snail is hidden rather than deleted precisely
        /// so this works.
        let home: Transform

        /// Already picked off. Not grabbable, and hidden once its fade finishes.
        var removed = false
    }

    /// The run. Read for phase gating (grab, snap-back) and written to for scoring —
    /// `scored()` on grab, `unscored()` on a snap-back release.
    private let game: GameSession

    /// `game.phase` as of the previous call to `update()`. A fresh run needs its picked-off
    /// snails put back, and nothing should stay grabbable once a run stops — both are phase
    /// transitions only this type needs to know about.
    private var lastPhase: GameSession.Phase = .idle

    /// For projecting/raycasting and reading `session.currentFrame`.
    private weak var arView: ARView?

    /// Every `Drupella*` entity across every loaded *simulation* model, flattened. Showcase
    /// models are never collected, which is the whole of "no pinch on a showcase card".
    private var snails: [Snail] = []

    /// The snail being dragged — its index into `snails` (so release can reach its `home` and
    /// flip `removed`) — and the camera distance it was grabbed at (held constant for the drag).
    /// `nil` also gates pickup to one at a time.
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

    /// Latest pinch point — `updateDrag()` reads this, set from each raw sample after
    /// `pinchPointFilter` damps it. No render-loop glide stage: gliding toward a target
    /// that itself only moves at `handPoseSampleInterval` (15 Hz) reads as steady-state lag.
    private var pinchPoint: CGPoint?

    /// Last sample that saw a hand at all, however poorly resolved — what the occlusion lock
    /// counts against, via `handInFrame`. A hand covering a card reads well enough here and
    /// badly above, so this is gated on the loose `handPresenceConfidence`, not
    /// `jointConfidenceMinimum`.
    private var lastHandSeenTime = Date.distantPast

    /// One Euro filter state for `pinchPoint` — reset (fresh `PinchPointFilter()`) whenever
    /// the hand is lost, so re-acquiring doesn't glide in from a stale position/derivative.
    private var pinchPointFilter = PinchPointFilter()

    /// `.soft` — firm grab, gentle let-go. `prepare()`d early to hide Taptic spin-up latency.
    private var pinchHaptics: UIImpactFeedbackGenerator?

    /// Fires once, on a snap-back release — a different generator, not another `.impact`
    /// intensity, so "put back, not collected" reads as its own kind of event rather than a
    /// third shade of grab/release.
    private var snapHaptics: UINotificationFeedbackGenerator?

    init(game: GameSession) {
        self.game = game
    }

    /// Whether a hand counts as being in frame right now — the occlusion lock's input. Holding a
    /// snail counts outright, since a hand mid-grab is unarguably there whatever the current
    /// sample managed to resolve.
    var handInFrame: Bool {
        held != nil || Date().timeIntervalSince(lastHandSeenTime) < handPresenceTimeout
    }

    /// Whether a hand is close enough to the lens that Vision cannot read a pinch from it — the
    /// state where nothing on screen responds and nothing says why, which is the whole reason it
    /// is surfaced.
    ///
    /// Two conditions, and **both** are required: the hand has to be measurably close
    /// (`handTooCloseSegmentFraction`, from a real on-screen size — see
    /// `longestFingerSegment(of:screenPoint:)`), *and* this sample has to have failed to produce a
    /// pinch. Closeness alone would nag through a hand that is close and working fine; unreadable
    /// alone is what an earlier version used, and it fired on every hand it could not read for any
    /// reason at all — one far enough away for the fingertips to fall below
    /// `jointConfidenceMinimum`, or one that had already left the frame, since `lastHandSeenTime`
    /// keeps saying "hand" for a whole `handPresenceTimeout` after the hand is gone.
    ///
    /// Written once per sample rather than derived from timestamps, so "no hand" is answered by
    /// the absence of a hand in *this* sample instead of by a clock that has not run out yet.
    private(set) var handTooClose = false

    /// Consecutive samples that read as too close — see `handTooCloseConfirmSamples`.
    private var tooCloseStreak = 0

    /// Wires up haptics against a live `ARView`. Call once, from `Coordinator.start(in:)`.
    func attach(to arView: ARView) {
        self.arView = arView
        pinchHaptics = UIImpactFeedbackGenerator(style: .soft, view: arView)
        snapHaptics = UINotificationFeedbackGenerator(view: arView)
    }

    /// Finds every entity named `Drupella*` in a loaded model and adds them to the grabbable
    /// pool. Call once per loaded *simulation* model — a showcase model's snails should never be
    /// collected, which is the whole implementation of "no pinch on a showcase card".
    func collectSnails(from model: Entity) {
        let (outlines, grabbable) = findDrupella(in: model).reduce(into: ([Entity](), [Entity]())) { result, entity in
            if entity.name.hasSuffix(outlineSuffix) {
                result.0.append(entity)
            } else {
                result.1.append(entity)
            }
        }

        // The source asset ships each snail's outline as a flat sibling, not a child — without
        // this it stays put on the coral while the real one gets dragged off. Re-parenting
        // (preserving its current world position, so it doesn't jump) makes it follow the drag.
        for outline in outlines {
            let snailName = String(outline.name.dropLast(outlineSuffix.count))
            guard let snail = grabbable.first(where: { $0.name == snailName }) else { continue }
            outline.setParent(snail, preservingWorldTransform: true)
        }

        snails.append(contentsOf: grabbable.map { Snail(entity: $0, home: $0.transform) })
    }

    private func findDrupella(in entity: Entity) -> [Entity] {
        var found = entity.name.hasPrefix(drupellaPrefix) ? [entity] : []
        for child in entity.children {
            found.append(contentsOf: findDrupella(in: child))
        }
        return found
    }

    /// One rendered frame's worth of pinch handling. Reacts to `game.phase` on its own — a run
    /// stopping drops whatever is held, a fresh run restores every picked-off snail — then
    /// samples Vision, drags the held snail, and steps any fade.
    func update() {
        // A snail still in hand when the run stops — buzzer, or the card walking out of frame —
        // is dropped rather than carried into whatever comes next. Safe to check every frame: it
        // is a no-op once `held` is already `nil`.
        if game.phase != .playing, held != nil {
            releaseHeld()
        }

        // Both entry points into a fresh run. Resuming out of `.grace` also lands in `.countdown`
        // or `.playing` and must *not* restore — that run is the same run, snails and all — which
        // is why these test where the phase came from.
        if (game.phase == .instructions && lastPhase != .instructions)
            || (game.phase == .countdown && lastPhase == .finished) {
            restoreAll()
        }
        lastPhase = game.phase

        sample()
        updateDrag()
        updateFading()
    }

    /// Puts every picked-off snail back where its model loaded, ready for another run.
    ///
    /// `home` is a *local* transform, so restoring it re-seats the snail on the coral wherever
    /// the coral currently is — dragging writes world-space positions into that same local
    /// transform, which is exactly what this undoes.
    private func restoreAll() {
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

    // MARK: Detection

    /// Size of `capturedImage` after being rotated upright by `imageOrientation` — what the
    /// aspect-fill math in `sample()` measures the crop against. A 90° rotation swaps width and
    /// height; `capturedImage` itself is always landscape.
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

    /// Longest visible finger segment, in screen points — how the app measures a hand's distance
    /// from the lens. `nil` when no two adjacent joints on any finger both resolved, which is a
    /// "cannot tell", never a "too close".
    ///
    /// Apparent segment length scales inversely with distance, and measuring *segments* rather
    /// than the span of the whole hand is what makes it survive the case it exists for: a hand
    /// against the lens has its wrist and most of its palm outside the frame, so any whole-hand
    /// measure collapses exactly when the hand is closest. Two adjacent joints on one finger are
    /// still visible. The longest pair wins rather than an average, because with a hand that
    /// close only a couple of segments resolve and any one of them being huge settles the question.
    ///
    /// Measured in screen points, not `Joint.distance(to:)`: that returns normalized units, where
    /// x and y are scaled by different numbers of pixels, so a diagonal segment's length depends on
    /// its orientation. Fine for `ratio`, which divides two such distances and cancels it out;
    /// useless against an absolute threshold.
    private func longestFingerSegment(of hand: HumanHandPoseObservation,
                                      screenPoint: (NormalizedPoint) -> CGPoint) -> CGFloat? {
        var longest: CGFloat?
        for chain in fingerJointChains {
            for (nearer, further) in zip(chain, chain.dropFirst()) {
                guard let a = hand.joint(for: nearer), a.confidence > jointConfidenceMinimum,
                      let b = hand.joint(for: further), b.confidence > jointConfidenceMinimum
                else { continue }
                let start = screenPoint(a.location), end = screenPoint(b.location)
                let length = hypot(start.x - end.x, start.y - end.y)
                if length > longest ?? 0 { longest = length }
            }
        }
        return longest
    }

    /// Records one sample's verdict, with `handTooCloseConfirmSamples` of hysteresis on the way in
    /// and none on the way out — a warning that lingered after the hand moved back, or vanished,
    /// would be worse than one that took an extra sample to appear.
    private func noteTooClose(_ tooClose: Bool) {
        guard tooClose else {
            tooCloseStreak = 0
            handTooClose = false
            return
        }
        tooCloseStreak += 1
        if tooCloseStreak >= handTooCloseConfirmSamples { handTooClose = true }
    }

    /// Samples the camera for a hand pinch, at most once every `handPoseSampleInterval`.
    /// Reads `session.currentFrame` from the render loop, same ARFrame-retention reason as
    /// the card pose filter in `PostcardARView.swift` — only `capturedImage` crosses into the
    /// `Task`, never the frame.
    private func sample() {
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

        // @MainActor so mutations below land on the same thread `update()` runs on;
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
                // No hand at all, so nothing can be too close. Asked of *this* sample, not of
                // `lastHandSeenTime`, which deliberately keeps reporting a hand for a second after
                // it leaves so the occlusion lock can hold — a tail this warning must not inherit.
                noteTooClose(false)
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

            // How close the hand actually is, for the bail-outs below — a real on-screen
            // measurement, so a hand that simply cannot be read (too far for the tips to clear
            // `jointConfidenceMinimum`, half out of frame) is not mistaken for one at the lens.
            // A live grip never counts: the wrist/knuckle guard further down fails routinely
            // during a genuine pinch, so this would otherwise fire on almost every drag.
            let tooClose = held == nil && !pinchClosed
                && (longestFingerSegment(of: hand, screenPoint: screenPoint) ?? 0)
                    >= viewportSize.width * handTooCloseSegmentFraction

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
                noteTooClose(tooClose)
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
            pinchPoint = filtered

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
            else {
                noteTooClose(tooClose)
                return
            }

            let handScale = wrist.distance(to: knuckle)
            guard handScale > 0 else {
                noteTooClose(tooClose)
                return
            }
            let ratio = Float(thumbJoint.distance(to: indexJoint) / handScale)

            // A pinch came out of this sample, so whatever the hand's distance, it is working.
            noteTooClose(false)
            evaluatePinch(ratio: ratio, at: filtered)
        }
    }

    /// Debounces one hand-pose sample into a grab or release.
    /// The point itself (`pinchPoint`) is already set by the caller — see `sample()` — since
    /// placing it doesn't depend on anything evaluated here.
    private func evaluatePinch(ratio: Float, at point: CGPoint) {
        lastPinchEvaluationTime = Date() // this sample is what the forced-release bail-outs were waiting for

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

    // MARK: Grab, drag, release

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
    /// `Coordinator.hold(_:)`. Depth stays fixed from grab time, so it tracks the screen at
    /// constant depth.
    private func updateDrag() {
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
    /// `removed` and keeping the point until `restoreAll()` puts it back for the next run.
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
    /// second load of a model already in memory. See `restoreAll()`.
    private func updateFading() {
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
}
