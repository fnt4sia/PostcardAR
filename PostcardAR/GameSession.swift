//
//  GameSession.swift
//  PostcardAR
//
//  The run that happens on a Simulation card: instructions, countdown, a timed spell of play, a
//  score. Both minigames share it unchanged — which one is running only decides how long the run
//  lasts and how many pieces finish it, both of which arrive in `begin(_:target:)`.
//
//  A plain state machine with a clock. It knows nothing about ARKit — the coordinator tells it
//  once a frame whether the card it belongs to is on screen, and it decides what that means. Two
//  reasons it is shaped that way: the render loop is already the one place per-frame work
//  happens, and "on screen" is a question only the coordinator can answer, because a card held by
//  the occlusion lock counts as present while ARKit reports it as not tracked.
//

import Foundation

/// The 3 · 2 · 1 between tapping Start and the first grab.
private let countdownDuration: TimeInterval = 3

/// How long a run survives with its card off camera and no hand to lock it. Long enough to
/// re-aim a phone, short enough that a run cannot be parked indefinitely.
private let graceDuration: TimeInterval = 3

/// One playthrough on one Simulation card.
///
/// Created by `ScannerScreen` and handed to both the AR view and the overlays, so the render
/// loop drives it and SwiftUI draws it.
@Observable
final class GameSession {
    /// Where the run is. `instructions`, `countdown` and `playing` need the card on screen;
    /// `idle`, `grace` and `finished` do not — `grace` *is* the wait for the card to come back,
    /// and on `finished` the player is reading a score rather than aiming the phone, so taking
    /// the result away for lowering the handset would be its own bug.
    ///
    /// `instructions` needs it for the opposite reason to `countdown` and `playing`: not because
    /// there is a run to protect, but because there is not one yet. See `update(cardPresent:now:)`.
    enum Phase {
        /// No run. A Simulation card coming into view starts one.
        case idle
        /// Dimmed instructions, waiting on Start. Needs the card: nothing has started, so the
        /// card leaving wipes the screen instead of parking it.
        case instructions
        /// 3 · 2 · 1.
        case countdown
        /// Live: the HUD is up and snails are grabbable.
        case playing
        /// Card gone and no hand to lock it. Clocks frozen, `graceSecondsRemaining` counting.
        case grace
        /// Time up. Score and Play Again.
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var score = 0

    /// Which game this run is, for the clock and for the words `ContentView` puts on screen. Set
    /// by `begin(_:target:)` and kept afterwards, so the result panel still knows what was played
    /// once the run is over. The value before the first run is never drawn.
    private(set) var minigame: Minigame = .removingDrupella

    /// Score that finishes the run outright — every snail on the card, or every plant point that
    /// has a coral to fill it. Counted from the model at load time; see
    /// `PinchInteraction.setup(for:)`.
    private(set) var target = 0

    /// Whole seconds, for the overlays. Written only when the displayed value actually changes:
    /// `@Observable` notifies on every set without comparing, and these are set once a frame.
    private(set) var secondsRemaining = 0
    private(set) var countdownNumber = Int(countdownDuration)
    private(set) var graceSecondsRemaining = Int(graceDuration)

    /// The clocks themselves, counted down in `update(cardPresent:now:)`.
    ///
    /// `@ObservationIgnored` throughout this block: these are written on every rendered frame and
    /// nothing draws them — the overlays read the whole-second properties above. Left tracked,
    /// each one would hit the observation registrar sixty times a second to tell nobody anything.
    @ObservationIgnored private var timeLeft: TimeInterval = 0
    @ObservationIgnored private var countdownLeft = countdownDuration
    @ObservationIgnored private var graceLeft = graceDuration

    /// What `grace` goes back to if the card returns in time.
    @ObservationIgnored private var phaseBeforeGrace: Phase = .playing

    /// Previous `update` timestamp, for the elapsed delta. Cleared whenever the clocks are
    /// reset, so a paused or freshly started run does not eat the time it spent stopped.
    @ObservationIgnored private var lastUpdate: Date?

    // MARK: Transitions

    /// A Simulation card has been seen and nothing is running: put the instructions up.
    ///
    /// - Parameters:
    ///   - minigame: what that card's model turned out to be, which fixes the run's length and
    ///     everything the player reads.
    ///   - target: how many pieces it holds — the score at which the run ends early.
    func begin(_ minigame: Minigame, target: Int) {
        guard phase == .idle else { return }
        self.minigame = minigame
        self.target = target
        restart(into: .instructions)
    }

    /// Start, from the instructions screen.
    func start() {
        guard phase == .instructions else { return }
        restart(into: .countdown)
    }

    /// Play Again, from the result screen.
    func playAgain() {
        guard phase == .finished else { return }
        restart(into: .countdown)
    }

    /// Back to nothing — the run is wiped and the next scan starts from zero.
    func reset() {
        restart(into: .idle)
    }

    /// A piece has actually been placed or picked off — a coral seated in a plant point, a snail
    /// carried clear of the coral and let go of. Both games call it at the moment their gesture
    /// succeeds and never before, so nothing here has to be taken back.
    ///
    /// **Reaching `target` ends the run on the spot.** Clearing the card is the object of both
    /// games, so achieving it is the ending — sitting out the rest of the clock with nothing left
    /// to pick up or plant is only a wait.
    func scored() {
        guard phase == .playing else { return }
        score += 1

        if target > 0, score >= target {
            timeLeft = 0
            phase = .finished
            publish()
        }
    }

    private func restart(into phase: Phase) {
        score = 0
        timeLeft = minigame.settings.duration
        countdownLeft = countdownDuration
        graceLeft = graceDuration
        lastUpdate = nil
        self.phase = phase
        publish()
    }

    // MARK: The clock

    /// One rendered frame's worth of time.
    ///
    /// - Parameter cardPresent: whether this run's card is on screen — tracked by ARKit *or*
    ///   held there by the occlusion lock. A locked card is still a card you can play on, which
    ///   is the whole reason the lock exists.
    func update(cardPresent: Bool, now: Date = Date()) {
        // No previous timestamp means the clocks were just reset: no time has passed yet.
        let delta = lastUpdate.map { now.timeIntervalSince($0) } ?? 0
        lastUpdate = now

        switch phase {
        case .idle, .finished:
            break // Nothing running, and nothing that needs the card in view.

        case .instructions:
            // Straight back to `idle`, with no grace period — the opposite of what losing the
            // card does further down. Grace exists to protect a score and a clock, and neither
            // has started yet, so there is nothing to hold: the screen goes away with the card
            // rather than sitting over a camera no longer pointed at one. The next card seen
            // puts the instructions back up from scratch.
            if !cardPresent { reset() }

        case .countdown:
            guard cardPresent else { enterGrace(); break }
            countdownLeft -= delta
            if countdownLeft <= 0 {
                countdownLeft = 0
                phase = .playing
            }

        case .playing:
            guard cardPresent else { enterGrace(); break }
            timeLeft -= delta
            if timeLeft <= 0 {
                timeLeft = 0
                phase = .finished
            }

        case .grace:
            // The run's own clocks are untouched here. Losing the card is not the player's
            // doing, and a timer draining behind a screen they cannot see would read as a cheat.
            if cardPresent {
                graceLeft = graceDuration
                phase = phaseBeforeGrace
                break
            }
            graceLeft -= delta
            if graceLeft <= 0 { reset() }
        }

        publish()
    }

    private func enterGrace() {
        phaseBeforeGrace = phase
        graceLeft = graceDuration
        phase = .grace
    }

    /// Rounds the clocks up to whole seconds for display. Up, not down, so a run reads "30" the
    /// instant it starts and only shows "0" when it really is over.
    private func publish() {
        let seconds = Int(timeLeft.rounded(.up))
        if secondsRemaining != seconds { secondsRemaining = seconds }

        let count = max(1, Int(countdownLeft.rounded(.up)))
        if countdownNumber != count { countdownNumber = count }

        let grace = max(0, Int(graceLeft.rounded(.up)))
        if graceSecondsRemaining != grace { graceSecondsRemaining = grace }
    }
}
