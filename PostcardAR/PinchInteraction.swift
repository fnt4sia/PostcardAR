//
//  PinchInteraction.swift
//  PostcardAR
//
//  The one gesture: pinch to grab a piece — a `Drupella*` snail or a `SingleCoral*` — drag it, let
//  go. Vision reads the same camera frame ARKit is already tracking cards against, independently
//  and at its own pace — see docs/interaction.md for the full mechanism.
//
//  Both minigames share every part of that. Where they differ is what a release means, and that
//  lives in exactly two places, both switching on the piece in hand (`Grabbable.game`) rather than
//  on any global mode: `releaseHeld()` and the plant-on-hover branch of `updateDrag()`. Each game's
//  settings and copy are in `Minigame.swift`.
//
//  `PostcardARView.Coordinator` owns one `PinchInteraction` and talks to it through five calls:
//  `attach(to:)` once at start, `collect(from:named:report:)` once per loaded simulation model,
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

/// Prefix marking a grabbable snail entity — see `collect(from:named:report:)`.
private let drupellaPrefix = "Drupella"

/// Prefix marking a slot on the structure that a coral can be planted into. A model containing any
/// of these *is* a planting card — see `collect(from:named:report:)`.
private let plantPointPrefix = "CoralPlantPoint"

/// Prefix marking a coral that can be picked up and planted.
private let singleCoralPrefix = "SingleCoral"

/// How close, **in screen points**, a released coral has to appear to a free plant point to snap
/// into it. Same units and the same idea as `pinchPickRadius`, and deliberately a little wider:
/// picking the wrong coral costs nothing, failing to plant one costs the point.
///
/// Screen distance, not world distance, and that is not a shortcut — see `plantTarget(for:)`.
///
/// A coral plants the moment it comes within this of a free slot, so the number is a balance rather
/// than a floor: too small and it is fiddly to land one, too large and a coral is taken out of your
/// hand while merely passing over a slot on the way to another.
private let plantSnapRadius: CGFloat = 80

/// Prefix marking the visible plate that stands for a plant point. Paired to its
/// `CoralPlantPoint*` by whatever follows the prefix — `CoralPlate_03` belongs to
/// `CoralPlantPoint_03` — the same idiom `Drupella_01_Outline` already uses.
///
/// Optional. A model without these plants corals exactly the same; it just has nothing to breathe,
/// so the player has to read the structure to see where a coral goes.
private let coralPlatePrefix = "CoralPlate"

/// A free slot's plate breathes between these opacities, so an empty socket reads as *waiting for
/// something* rather than as one more piece of structure. The plate itself is the model's, and its
/// size, shape and place are none of our business — only how strongly it is drawn.
private let plantPulseMinOpacity: Float = 0.3
private let plantPulseMaxOpacity: Float = 1.0

/// Seconds for one full breath.
private let plantPulsePeriod: TimeInterval = 1.3

/// How far, in screen points, a coral must be carried before it is allowed to plant.
///
/// Without this a coral authored sitting on or beside a free slot — which is exactly how a planting
/// board is likely to be laid out — would satisfy `plantTarget(for:)` on the very frame it was
/// picked up, plant itself instantly, and be impossible to move at all. Arming on travel means the
/// player has to actually carry it somewhere, and costs nothing when the corals start further away.
private let plantArmDistance: CGFloat = 50

/// Suffix marking a snail's separate outline mesh. Shipped as a flat sibling of its snail in the
/// source asset, not a child; `collectDrupella(from:snails:)` matches it to strip it out of the grabbable
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
    /// One grabbable piece — a drupella snail, or a coral waiting to be planted.
    private struct Grabbable {
        let entity: Entity

        /// What game it belongs to, and so what letting go of it does. Carried per piece rather
        /// than held once for the type: the pool is shared across every loaded simulation model,
        /// and two cards running different games can be in frame together. See `Minigame.swift`.
        let game: Minigame

        /// The model it came from. Plant points are matched against this, so a coral can only be
        /// planted on its own structure and not on another card's.
        let model: Entity

        /// The local transform it loaded with — where a snap-back release and Play Again put it
        /// back. The same thing for both games: a snail's place on the coral, a coral's place in
        /// whatever arrangement the model was authored with. Released pieces are hidden rather than
        /// deleted precisely so this works.
        let home: Transform

        /// Out of play — a snail picked off, or a coral planted. Not grabbable either way.
        var removed = false
    }

    /// One place on the structure a coral can be planted.
    private struct PlantPoint {
        /// The `CoralPlantPoint*` entity, left exactly as the model ships it. Its transform is the
        /// slot: what the snap test aims at, and the pose a planted coral takes. Nothing here draws
        /// anything or touches the entity — whatever the model puts at that point is what shows.
        let entity: Entity

        /// The model it belongs to, matched against `Grabbable.model`.
        let model: Entity

        /// The `CoralPlate*` that stands for this slot on screen, if the model ships one. Pulsed
        /// while the slot is free — see `updatePlantIndicators()`. Never moved, never resized: the
        /// model owns what it looks like, this only decides how strongly it is drawn.
        let plate: Entity?

        /// Taken by a coral. A planted coral is not re-grabbable, so this never goes back to `false`
        /// except in `restoreAll()`.
        var filled = false

        /// Opacity last written to `plate`, so a slot that is not currently breathing — filled, or
        /// the live target — is not rewritten sixty times a second to the same value.
        var plateOpacity: Float = -1
    }

    /// The run. Read for phase gating (grab, snap) and written to for scoring — `scored()` where
    /// each game's gesture actually succeeds: `plant(_:in:)` for a coral, `releaseSnail(_:)` for a
    /// snail that comes off rather than going back on.
    private let game: GameSession

    /// `game.phase` as of the previous call to `update()`. A fresh run needs its picked-off
    /// snails put back, and nothing should stay grabbable once a run stops — both are phase
    /// transitions only this type needs to know about.
    private var lastPhase: GameSession.Phase = .idle

    /// For projecting/raycasting and reading `session.currentFrame`.
    private weak var arView: ARView?

    /// Every grabbable piece across every loaded *simulation* model, flattened. Showcase models are
    /// never collected, which is the whole of "no pinch on a showcase card".
    private var grabbables: [Grabbable] = []

    /// Every plant point across every loaded planting model. Empty when no such card is loaded.
    private var plantPoints: [PlantPoint] = []

    /// What each loaded simulation card turned out to be, keyed by card name — filled in
    /// `collect(from:named:report:)`, read once by the coordinator when a card claims the session.
    /// A card whose model has not arrived yet, or holds nothing to play with, is simply absent.
    private var setups: [String: (minigame: Minigame, target: Int)] = [:]

    /// The piece being dragged — its index into `grabbables` (so release can reach its `home` and
    /// flip `removed`) — and the camera distance it was grabbed at (held constant for the drag).
    /// `nil` also gates pickup to one at a time.
    private var held: (index: Int, depth: Float)?

    /// Released snails, fading toward `opacity == 0` before being hidden. Corals never fade: an
    /// unplanted one glides back to where it started instead of leaving play.
    private var fading: [(entity: Entity, opacity: Float)] = []

    /// Where the pinch was when the held piece was grabbed, and whether it has since been carried
    /// `plantArmDistance` from there. A coral may only plant once it has — see that constant.
    private var heldGrabPoint: CGPoint?
    private var heldHasTravelled = false

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

    /// What a card plays and how many pieces finish it, or `nil` if its model has not loaded yet
    /// or holds nothing to play with. Read by `Coordinator.updateGame(cardPresent:candidate:)` to
    /// start a run: a card with no answer here does not claim the session, which is what keeps the
    /// instructions panel off a card that has nothing on it.
    func setup(for card: String) -> (minigame: Minigame, target: Int)? { setups[card] }

    /// Wires up haptics against a live `ARView`. Call once, from `Coordinator.start(in:)`.
    func attach(to arView: ARView) {
        self.arView = arView
        pinchHaptics = UIImpactFeedbackGenerator(style: .soft, view: arView)
        snapHaptics = UINotificationFeedbackGenerator(view: arView)
    }

    /// Reads a loaded *simulation* model and adds whatever it can be played with to the pool. Call
    /// once per simulation model — a showcase model is never collected, which is the whole
    /// implementation of "no pinch on a showcase card".
    ///
    /// **The model decides which minigame it is**, by what it contains: `CoralPlantPoint*` entities
    /// mean planting, `Drupella*` mean removal. That keeps adding a card to dropping two files with
    /// no code change and no second naming rule layered on the `Simulation` prefix — and it is the
    /// same idiom the prefixes themselves use. A model with neither is reported rather than silently
    /// standing there doing nothing.
    ///
    /// Neither game moves anything at load time: a snail and a coral alike start exactly where the
    /// model puts them, and that authored transform is the `home` they are restored to.
    func collect(from model: Entity, named name: String, report: (String) -> Void) {
        let points = find(prefix: plantPointPrefix, in: model)
        if !points.isEmpty {
            collectPlanting(from: model, named: name, points: points, report: report)
            return
        }

        let snails = find(prefix: drupellaPrefix, in: model)
        if !snails.isEmpty {
            collectDrupella(from: model, named: name, snails: snails)
            return
        }

        report("""
            \(name).usdz is a Simulation card but has no \(plantPointPrefix)* or \(drupellaPrefix)* \
            entities, so there is nothing to play with on it.
            """)
    }

    /// The removal game: every `Drupella*` becomes grabbable where it sits on the coral.
    private func collectDrupella(from model: Entity, named name: String, snails: [Entity]) {
        let (outlines, pickable) = snails.reduce(into: ([Entity](), [Entity]())) { result, entity in
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
            guard let snail = pickable.first(where: { $0.name == snailName }) else { continue }
            outline.setParent(snail, preservingWorldTransform: true)
        }

        grabbables.append(contentsOf: pickable.map {
            Grabbable(entity: $0, game: .removingDrupella, model: model, home: $0.transform)
        })
        // Every snail on the card: clearing them all is what ends the run early.
        setups[name] = (.removingDrupella, pickable.count)
    }

    /// The planting game: the plant points are registered and hidden, and every `SingleCoral*` is
    /// left exactly where it was authored, grabbable in place.
    private func collectPlanting(from model: Entity, named name: String,
                                 points: [Entity], report: (String) -> Void) {
        let corals = find(prefix: singleCoralPrefix, in: model)

        guard !corals.isEmpty else {
            report("\(name).usdz has plant points but no \(singleCoralPrefix)* corals to plant.")
            return
        }
        if corals.count < points.count {
            report("""
                \(name).usdz has \(corals.count) \(singleCoralPrefix)* for \(points.count) \
                \(plantPointPrefix)*, so \(points.count - corals.count) can never be filled.
                """)
        }

        // Registered as they are: a plant point is a *place*, and what it looks like stays the
        // model's business. Where one ships a `CoralPlate*` alongside, that plate is picked up here
        // so `updatePlantIndicators()` can breathe it — drawing attention to the model's own shape
        // rather than covering it with one of ours.
        // The suffix has to match *exactly*, not merely start with: the prefix search also returns
        // each plate's own `CoralPlate_03_mesh` child, and a prefix test would pair the point with
        // whichever of the two came back first.
        let plates = find(prefix: coralPlatePrefix, in: model)
        plantPoints.append(contentsOf: points.map { point in
            let suffix = point.name.dropFirst(plantPointPrefix.count)
            return PlantPoint(entity: point,
                              model: model,
                              plate: plates.first { $0.name.dropFirst(coralPlatePrefix.count) == suffix })
        })

        // Left exactly where the model puts them, like the snails. Whatever arrangement the asset
        // was authored with *is* the arrangement, and it is also the `home` an unplanted coral
        // glides back to and the one Play Again restores.
        grabbables.append(contentsOf: corals.map {
            Grabbable(entity: $0, game: .plantingCoral, model: model, home: $0.transform)
        })
        // The smaller of the two, not the number of slots: a board shipping fewer corals than
        // points can never fill them all, and a target that cannot be reached would never end the
        // run early — the mismatch is already reported above.
        setups[name] = (.plantingCoral, min(corals.count, points.count))
    }

    /// Breathes the plate on every free slot, and holds the one a held coral would drop into solid.
    /// Runs once a rendered frame, from `update()`.
    ///
    /// **Nothing is drawn and nothing is moved.** Two earlier attempts at an indicator built geometry
    /// of the app's own — a disc sized against the corals — and both failed on sizing: on a board
    /// whose slots sit closer together than its corals are wide, the discs overlapped into a single
    /// blob. The model already knows how big a socket is and where it faces, so the only thing left
    /// worth doing is making its own plate impossible to miss. Opacity is the whole mechanism.
    ///
    /// Three states, and the difference between the first two is the signal:
    ///
    /// | Slot | Plate |
    /// |---|---|
    /// | free | breathing between `plantPulseMinOpacity` and `plantPulseMaxOpacity` |
    /// | about to take the coral in hand | solid, and the only steady one on the board |
    /// | filled | solid, and left alone — it is structure again |
    ///
    /// The target is read from `plantTarget(for:)` under the same arming gate `updateDrag()` uses,
    /// so a plate never goes solid for a plant that would not actually happen.
    private func updatePlantIndicators() {
        guard !plantPoints.isEmpty else { return }

        let target = heldHasTravelled ? held.flatMap { plantTarget(for: $0.index) } : nil
        // A sine over wall-clock time rather than a frame counter: the breath then keeps its period
        // on a device rendering at 30 fps as readily as at 60.
        let breath = (sin(Date().timeIntervalSinceReferenceDate * 2 * .pi / plantPulsePeriod) + 1) / 2
        let pulse = plantPulseMinOpacity
            + Float(breath) * (plantPulseMaxOpacity - plantPulseMinOpacity)

        for index in plantPoints.indices {
            guard let plate = plantPoints[index].plate else { continue }

            let opacity = plantPoints[index].filled || index == target ? plantPulseMaxOpacity : pulse

            // A breathing plate changes every frame and is written every frame; a solid one settles
            // and stops being touched.
            guard abs(plantPoints[index].plateOpacity - opacity) > 0.005 else { continue }
            plantPoints[index].plateOpacity = opacity
            plate.components.set(OpacityComponent(opacity: opacity))
        }
    }

    /// The free plant point a coral would snap into if released now, or `nil` for none in range.
    ///
    /// **Measured on screen, not in the world**, and that is the fix for corals that would not snap
    /// at all. A held piece is dragged along the ray through the pinch point at the depth it was
    /// grabbed at (`updateDrag()`), so it rides a sphere around the camera. A coral picked up in
    /// front of the structure therefore stays in front of it however carefully it is aimed: lining
    /// it up with a plant point on screen leaves the two still centimetres apart in depth, and a
    /// world-space radius small enough to be meaningful never fires. The player is aiming at a
    /// picture, so the test has to be against the picture.
    ///
    /// The coral's own projected position is used rather than the pinch point, so what is tested is
    /// where the coral *appears* — which is what the player is lining up.
    private func plantTarget(for index: Int) -> Int? {
        guard grabbables[index].game == .plantingCoral, let arView,
              let coral = arView.project(grabbables[index].entity.position(relativeTo: nil))
        else { return nil }

        return plantPoints.indices
            .filter { !plantPoints[$0].filled && plantPoints[$0].model === grabbables[index].model }
            .compactMap { point -> (Int, CGFloat)? in
                guard let projected = arView.project(plantPoints[point].entity.position(relativeTo: nil))
                else { return nil }
                return (point, hypot(projected.x - coral.x, projected.y - coral.y))
            }
            .filter { $0.1 < plantSnapRadius }
            .min { $0.1 < $1.1 }?.0
    }

    private func find(prefix: String, in entity: Entity) -> [Entity] {
        var found = entity.name.hasPrefix(prefix) ? [entity] : []
        for child in entity.children {
            found.append(contentsOf: find(prefix: prefix, in: child))
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
        updatePlantIndicators()
    }

    /// Puts every picked-off snail back where its model loaded, ready for another run.
    ///
    /// `home` is a *local* transform, so restoring it re-seats the snail on the coral wherever
    /// the coral currently is — dragging writes world-space positions into that same local
    /// transform, which is exactly what this undoes.
    private func restoreAll() {
        // `update()` releases anything held before it gets here, so this is belt and braces — but a
        // piece dropped while still marked "draw over everything" would stay that way forever, and
        // the invariant is cheaper to keep locally than to rely on a call order elsewhere.
        if let (index, _) = held {
            setDrawsInFront(false, on: grabbables[index].entity)
        }
        held = nil
        heldGrabPoint = nil
        heldHasTravelled = false
        fading.removeAll()
        for index in grabbables.indices {
            let entity = grabbables[index].entity
            entity.transform = grabbables[index].home
            entity.components.remove(OpacityComponent.self)
            entity.isEnabled = true
            grabbables[index].removed = false
        }
        // Empty the structure too, or a second planting run starts with every slot already taken.
        for index in plantPoints.indices {
            plantPoints[index].filled = false
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

        let nearest = grabbables.indices
            .compactMap { index -> (Int, CGFloat)? in
                // Out of play, or on a card that is not on screen: not there to grab.
                guard !grabbables[index].removed,
                      grabbables[index].entity.isEnabledInHierarchy,
                      let projected = arView.project(grabbables[index].entity.position(relativeTo: nil))
                else { return nil }
                return (index, hypot(projected.x - point.x, projected.y - point.y))
            }
            .filter { $0.1 < pinchPickRadius }
            .min { $0.1 < $1.1 }

        guard let (index, _) = nearest else { return }
        let piece = grabbables[index].entity
        let depth = simd_distance(SIMD3(cameraPosition.x, cameraPosition.y, cameraPosition.z),
                                   piece.position(relativeTo: nil))
        grabbables[index].removed = true
        held = (index, depth)
        heldGrabPoint = point
        heldHasTravelled = false
        // Carried pieces draw over the hand carrying them; everything else stays behind it.
        setDrawsInFront(true, on: piece)
        pinchHaptics?.impactOccurred()

        // Nothing is scored here, in either game. A grab is a piece in hand and no more: a coral
        // may never reach a plant point, and a snail may be put straight back on the coral. Both
        // games score where their gesture actually succeeds — `plant(_:in:)` and `releaseSnail(_:)`.
    }

    /// Moves the held snail to the last pinch point every rendered frame — same idiom as
    /// `Coordinator.hold(_:)`. Depth stays fixed from grab time, so it tracks the screen at
    /// constant depth.
    private func updateDrag() {
        guard let (index, depth) = held, let point = pinchPoint,
              let arView, let ray = arView.ray(through: point)
        else { return }
        grabbables[index].entity.setPosition(ray.origin + ray.direction * depth, relativeTo: nil)

        // Armed once the piece has actually been carried somewhere, so a coral that starts within
        // reach of a free slot is not planted the instant it is picked up.
        if !heldHasTravelled, let start = heldGrabPoint,
           hypot(point.x - start.x, point.y - start.y) > plantArmDistance {
            heldHasTravelled = true
        }

        // A coral commits the instant it is over a free slot, rather than waiting to be let go of.
        // Landing it is the object of the game, so the moment it is achieved is the moment to take
        // it out of the player's hand — and it means the success path never depends on reading the
        // exact frame a pinch opens, which is the least reliable thing Vision does.
        if grabbables[index].game == .plantingCoral, game.phase == .playing, heldHasTravelled,
           let slot = plantTarget(for: index) {
            plant(index, in: slot)
        }
    }

    /// Seats a coral in a slot: out of the hand, out of play, scored. This is the planting game's
    /// one scoring point — the moment the gesture actually succeeds, the same way `releaseSnail(_:)`
    /// is the removal game's.
    ///
    /// The coral takes the slot's position and rotation but keeps its own scale — a plant point
    /// authored as a cube shrunk to 10% carries that scale, and adopting it would shrink the coral
    /// the moment it was planted. It also keeps the `removed` flag it got at the grab, which is what
    /// stops it being picked back off the structure.
    private func plant(_ index: Int, in slot: Int) {
        let entity = grabbables[index].entity
        held = nil
        setDrawsInFront(false, on: entity)

        let pose = Transform(matrix: plantPoints[slot].entity.transformMatrix(relativeTo: entity.parent))
        entity.move(to: Transform(scale: entity.transform.scale,
                                  rotation: pose.rotation,
                                  translation: pose.translation),
                    relativeTo: entity.parent, duration: pinchSnapDuration)

        plantPoints[slot].filled = true
        game.scored()
        snapHaptics?.notificationOccurred(.success)
    }

    /// Draws an entity and everything under it over the top of the scene, or puts it back.
    ///
    /// Used on whatever is currently held, and on nothing else. ARKit's people occlusion mattes the
    /// player's hand in front of the models by depth, which is right for the coral being reached
    /// *past* and wrong for the one being carried: a snail pinched off vanishes behind the fingers
    /// holding it. `readsDepth = false` takes the held piece out of the depth test, so it draws over
    /// the hand — and over the model — for as long as it is held. Everything else keeps occluding
    /// normally, which is the point.
    ///
    /// Materials are value types held in a `ModelComponent`, so each has to be read, changed and put
    /// back. `readsDepth` is not on the `Material` protocol, only on the concrete types, hence the
    /// switch; anything unrecognised is left alone rather than dropped.
    private func setDrawsInFront(_ inFront: Bool, on entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                switch material {
                case var pbr as PhysicallyBasedMaterial: pbr.readsDepth = !inFront; return pbr
                case var unlit as UnlitMaterial: unlit.readsDepth = !inFront; return unlit
                case var simple as SimpleMaterial: simple.readsDepth = !inFront; return simple
                default: return material
                }
            }
            entity.components.set(model)
        }
        for child in entity.children {
            setDrawsInFront(inFront, on: child)
        }
    }

    /// Lets go of the held piece, into whichever release rule its game has.
    private func releaseHeld() {
        guard let (index, _) = held else { return }
        held = nil
        // Back into the depth test the moment it leaves the hand, whatever happens to it next.
        setDrawsInFront(false, on: grabbables[index].entity)

        switch grabbables[index].game {
        case .removingDrupella: releaseSnail(index)
        case .plantingCoral: releaseCoral(index)
        }
    }

    /// A snail let go of. Near enough its home slot, and with the run still live, that reads as
    /// "put back" rather than "collected": it glides home and returns to play, scoring nothing.
    /// Otherwise it fades out, stays out, and **this** is where the removal game scores.
    ///
    /// Scoring here rather than at the grab is what makes the point mean what it says: the snail
    /// has left the coral. A grab is only a snail in hand, and the player may well put it straight
    /// back — which used to score and then un-score, a point appearing and vanishing for a gesture
    /// that achieved nothing.
    ///
    /// The score is gated on `phase == .playing` inside `GameSession.scored()`, so a snail still in
    /// hand when the buzzer goes — `update()` drops it the moment the phase leaves `playing` —
    /// fades away without counting, the same as one released after the run ended.
    private func releaseSnail(_ index: Int) {
        let entity = grabbables[index].entity

        var snapping = false
        if game.phase == .playing, let parent = entity.parent {
            let home = parent.convert(position: grabbables[index].home.translation, to: nil)
            snapping = simd_distance(home, entity.position(relativeTo: nil)) < pinchSnapRadius
        }

        if snapping {
            entity.move(to: grabbables[index].home, relativeTo: entity.parent,
                        duration: pinchSnapDuration)
            grabbables[index].removed = false
            snapHaptics?.notificationOccurred(.success)
        } else {
            fading.append((entity, 1))
            game.scored()
            pinchHaptics?.impactOccurred(intensity: 0.4) // softer than the grab: this end is expected
        }
    }

    /// A coral let go of. Close enough to a free plant point on **its own** structure, and it snaps
    /// in and scores; anything else glides back to where it started.
    ///
    /// A coral is never lost and never fades. There is no way to run a planting board out of corals
    /// by fumbling, which matters because there are only ever as many corals as the model ships —
    /// and a coral left floating wherever the hand happened to open would be both ugly and, once it
    /// drifted off camera, unreachable.
    private func releaseCoral(_ index: Int) {
        // Ordinarily unreachable: `updateDrag()` plants a coral the moment it is over a free slot,
        // so a coral still in hand at release is one that was not over anything. Checked anyway for
        // the frame where arriving and letting go coincide — under the same arming gate, so letting
        // go without having carried the coral anywhere puts it back rather than planting it where
        // it already was.
        if game.phase == .playing, heldHasTravelled, let slot = plantTarget(for: index) {
            plant(index, in: slot)
            return
        }

        // Nowhere to put it: back where it started, still in play and still the piece it was —
        // the same thing letting go of a snail away from its slot does.
        let entity = grabbables[index].entity
        entity.move(to: grabbables[index].home, relativeTo: entity.parent,
                    duration: pinchSnapDuration)
        grabbables[index].removed = false
        pinchHaptics?.impactOccurred(intensity: 0.4)
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
