//
//  Minigame.swift
//  PostcardAR
//
//  The two minigames, in one place.
//
//  Which game a simulation card runs is read from its model's contents, not from its name —
//  `CoralPlantPoint*` inside it means planting, `Drupella*` means removal. See
//  `PinchInteraction.collect(from:named:report:)`, which does that reading and records the answer
//  per card.
//
//  This file holds everything about a game that is a *setting* rather than a rule: how long a run
//  lasts and every word the player reads. One `Settings` literal per game, so adding a card of an
//  existing kind is still no code change and re-wording or re-timing a game is one block to edit.
//
//  The *rules* deliberately do not live here. What a grab and a release mean is the difference
//  between the two games and is spread over exactly two places, both of which switch on the piece
//  in hand rather than on a global mode: `PinchInteraction.releaseHeld()` and `updateDrag()`.
//  Folding those into this enum would mean handing it the entity pool, the ARView and the session
//  to work on — a manager, for no gain. See docs/simulation.md.
//

import Foundation

/// Which minigame a grabbable piece belongs to, and therefore what picking it up and letting go
/// of it mean.
///
/// Carried per piece rather than held once for the whole app, because the grabbable pool is shared
/// across every loaded simulation model and two cards running different games can be in frame
/// together. A `GameSession` also holds the one its current run belongs to, for the copy and the
/// clock below.
enum Minigame {
    /// Drupella are eating the coral: pinch them off.
    case removingDrupella

    /// Corals sit around a structure: pinch them onto its plant points.
    case plantingCoral

    /// One game's tunables and copy. Read by `GameSession` for the clock and by `ContentView` for
    /// the instructions and result panels; nothing else needs it.
    struct Settings {
        /// How long a run of this game lasts. Planting is the slower gesture — a coral has to be
        /// carried to a specific slot, where a snail only has to be lifted off — so it gets longer.
        let duration: TimeInterval

        /// Headline on the instructions panel.
        let title: String

        /// Body of the instructions panel.
        let instructions: String

        /// Small label above the score on the result panel.
        let resultLabel: String

        /// Headline under the score on the result panel.
        let resultTitle: String
    }

    var settings: Settings {
        switch self {
        case .removingDrupella:
            Settings(
                duration: 30,
                title: "THE SILENT KILLER",
                instructions: """
                    Drupella snails are eating the coral! Pinch one with your thumb and finger to pull it off.
                    Clear as many as you can in 30 seconds.
                    """,
                resultLabel: "CLEARED",
                resultTitle: "DRUPELLA REMOVED"
            )

        case .plantingCoral:
            Settings(
                duration: 45,
                title: "REBUILD THE REEF",
                instructions: """
                    The biorock frame is bare. Pinch a coral with your thumb and finger and carry it onto a glowing plate.
                    Plant as many as you can in 45 seconds.
                    """,
                resultLabel: "PLANTED",
                resultTitle: "CORAL PLANTED"
            )
        }
    }
}
