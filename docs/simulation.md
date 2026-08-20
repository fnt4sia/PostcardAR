# Simulation cards and the run

A card is one of two kinds, and the kind is the front of its name:

| Kind | Prefix | What it does |
|---|---|---|
| **Showcase** | anything else | Stands its model up to be looked at. Model appears while the card is tracked and hides when it is not. No lock, no pinch, no UI. |
| **Simulation** | `Simulation` | A minigame runs on it. The occlusion lock may hold its model on screen under a hand, its grabbable entities enter the pool, and detecting it starts a run. |

```swift
private let simulationCardPrefix = "Simulation"
...
kind: name.hasPrefix(simulationCardPrefix) ? .simulation : .showcase
```

The type travels in the name for the same reason the model does: adding a card stays two files
and no code change, and nothing in the source names an individual card. It is the same idiom as
the `Drupella` prefix that `PinchInteraction.collect(from:named:report:)` matches on. `Showcase` as
a prefix is a convention for readability only — the code tests for `Simulation` and treats
everything else as showcase, so an unprefixed card is a showcase card.

Renaming a card to change its kind means renaming its `.usdz` too; the pairing is still by exact
name. See [reference-images.md](reference-images.md) and [models.md](models.md).

## What the two kinds actually differ in

Three things, and nothing else:

| | Showcase | Simulation |
|---|---|---|
| Occlusion lock | never — hides the instant its card is lost | holds the model under a hand, per [tracking.md](tracking.md) |
| Grabbable entities collected into the pool | no | yes |
| Seeing the card starts a `GameSession` | no | yes |

The lock is a simulation-only feature because of what it is *for*. It exists so that reaching into
the scene does not delete the thing you are reaching for — a hand across the card is both the
ordinary way ARKit loses the card and the exact moment the player is grabbing a snail. A showcase
card has nothing to reach for, so a hand passing over it has no reason to keep a model frozen in
mid-air after the card has gone.

Showcase models never enter `grabbables`, which is the whole implementation of "no pinch on a
showcase card" — `attemptGrab(at:)` has nothing to find on one, with no extra test.

Annotations are **not** on that list, and deliberately so: a model carrying `Annotation*` entities
gets labels whatever kind of card it is on. See [annotations.md](annotations.md).

## Which minigame — read from the model, not the name

There are two, and a simulation card's `.usdz` says which one it is by what is inside it:

| Model contains | Game | Grabbable | Target |
|---|---|---|---|
| `CoralPlantPoint*` | **PlantingCoral** | `SingleCoral*` | the plant points |
| `Drupella*` (and no plant points) | **RemovingDrupella** | `Drupella*` | — |
| neither | none — reported to the status panel | | |

```swift
enum Minigame {
    case removingDrupella
    case plantingCoral
}
```

The alternative was a second naming rule stacked on the `Simulation` prefix —
`Simulation_Planting_*` against `Simulation_Drupella_*`. Reading the contents instead keeps the
promise that adding a card is dropping files and changing no code, and leaves one convention to
remember instead of two that have to agree across the reference image *and* the `.usdz` name. It is
also the same idiom the entity prefixes already use: the model declares what it holds by naming, and
the source names no individual card.

Plant points are checked first, so a planting model that also contains a stray `Drupella*` is still a
planting model rather than being silently misread.

**The game is recorded per grabbable piece, not once for the app.** The pool is shared across every
loaded simulation model, and two cards running different games can be in frame together, so
`releaseHeld()` asks the piece in hand what it is. That also means it never needs to know which card
the current run belongs to.

## PlantingCoral

Corals are stacked beside a structure; pinch them onto its plant points.

```
        ▓ SingleCoral_05   ← only this one can be picked up
        ▓ SingleCoral_04
        ▓ SingleCoral_03
  ╔═══════════╗ ▓ _02
  ║ structure ║ ▓ _01
  ║  ·  ·  ·  ║          · = CoralPlantPoint_01…03
  ╚═══════════╝
   └ the card ┘
```

**The pile is built by the app, not by the asset.** Whatever transform a `SingleCoral*` was authored
with is discarded: `stack(_:in:structure:)` puts them off the structure's right-hand edge, climbing
from its base, at offsets expressed as fractions of the structure's own size so they hold at any
export scale. Author the corals wherever is convenient — they will be moved.

Three details in that which are easy to get wrong:

- **It is card-relative, not viewer-relative.** `+x` is across the printed card's width, so from the
  far side of the card the pile is on your left.
- **Each coral is re-parented onto the model root first**, preserving its world transform. Without
  that, `coral.transform` means "within whatever group the artist nested it in", and a translation
  written there lands somewhere else entirely once an ancestor carries an offset or a scale.
  Preserving the world transform bakes any ancestor scale into the coral's own transform, so it still
  looks exactly as authored and only its position is ours to overwrite.
- **The structure is measured without the corals.** `structureBounds(of:)` skips `SingleCoral*`
  subtrees, and the result is handed to `fit(_:named:bounds:)` as what to size and centre the model
  by. Both halves matter: measuring with the corals at their authored positions would scale the model
  by something meaningless, and measuring with the pile included would shrink the structure to make
  room for a pile that is *supposed* to hang off the card. This is why `collect` runs **before**
  `fit` — see `loadModels()`.

**Only the top of the pile is grabbable.** `isOnTopOfItsStack(_:)` passes a coral only when no coral
of its own model is both still in play and higher up. Snails have no `stackIndex` and always pass.

**Releasing.** Close enough to a free plant point on its *own* structure (`plantSnapRadius`, more
generous than the drupella `pinchSnapRadius` — putting a snail back is recovering from a mistake,
landing a coral is the object of the game) and it snaps in and scores. Anything else glides back to
its slot in the pile.

A coral is never lost and never fades. The pile is finite, so a fumbled release must not be able to
run the board out of corals, and a coral left floating wherever the hand happened to open would be
both ugly and unreachable.

A planted coral is **not** re-grabbable — a plant is committed, like a removed snail — so
`unscored()` is a drupella-only affair.

The coral takes the plant point's position and rotation but **keeps its own scale**. A plant point is
a marker, and one authored as a cube shrunk to 10% carries that scale in its transform; adopting it
wholesale would shrink the coral the moment it was planted.

## RemovingDrupella

Drupella snails are eating the coral; pinch them off. The original game, and the simpler one: the
snails are grabbable exactly where they were authored, there is nowhere to put them, and a released
snail fades out and stays out.

It scores at the **grab**, not the release, because a grabbed snail always ends up removed — see
"Scoring, and putting the snails back" below, including the one case that reverses it.

Each snail's outline mesh ships as a flat sibling rather than a child and is re-parented under its
snail at load time, or it would stay behind on the coral while the snail is dragged off. Details in
"Finding the pieces" in [interaction.md](interaction.md).

## The run

One `GameSession`, in `GameSession.swift`. It knows nothing about ARKit: the coordinator tells it
once a rendered frame whether the card it belongs to is on screen, and it decides what that means.

```
  idle ──card seen──▶ instructions ──Start──▶ countdown ──▶ playing ──30s──▶ finished
    ▲    ◀──card gone──┘               │            │            │              │
    │      (nothing kept)              │            │            │              │
    │                    card gone, no hand in frame │            │         Play Again
    │                                  ▼            ▼            ▼              │
    └────────── 5 s elapsed ────────── grace ◀───────┴────────────┘              │
                                         │                                       │
                                         └── card back ──▶ resume ◀──────────────┘
                                             (same score, same clock)
```

| Phase | Screen | Card needed | Losing it |
|---|---|---|---|
| `idle` | nothing but the status panel | — | — |
| `instructions` | dimmed panel, what to do, **Start** | yes | straight to `idle`, no grace |
| `countdown` | 3 · 2 · 1 | yes | `grace` |
| `playing` | score top left, clock top right, snails grabbable | yes | `grace` |
| `grace` | "point at the card again" and 5 · 4 · 3 · 2 · 1 | it is what is being waited for | — |
| `finished` | *Time's up*, score, **Play Again** / **Close** | no | — |

**`idle` and `finished` are the only phases the card can leave freely.** On the result screen the
player is reading a score rather than aiming the phone, so it stays up until it is dismissed,
however the handset is pointed.

**`instructions` needs the card, but for the opposite reason to `countdown` and `playing`.** Those
two have a score and a clock to protect, which is what `grace` is for. Instructions has neither —
nothing has started — so there is nothing worth holding, and the panel goes away with the card
rather than sitting over a camera that is no longer pointed at one. `update(cardPresent:now:)`
calls `reset()` on it directly, with no grace period and no state carried over; the next card seen
puts the instructions back from scratch.

That makes one ordering detail load-bearing in `Coordinator.updateGame(cardPresent:candidate:)`.
`cardPresent` is worked out in the card loop that runs *before* it, back when `activeSimulationCard`
was still `nil` — so on the very frame a card claims the session it reads `false`, however plainly
the card is in view. Passing that straight through would send the `instructions` phase `begin()`
just started back to `idle` on the same frame, and the two would alternate forever. The claim
branch therefore overrides it to `true`, which is sound because `candidate` is only ever set from a
card that was *tracked* this frame.

## Losing the card mid-run

This is about `countdown` and `playing` — a run that is under way. `instructions` losing its card
is not a loss mid-run but a run that never started, and is handled above.

Two different situations, told apart by the same `handInFrame` the occlusion lock runs on.

**Card lost, hand in frame.** The lock holds the model exactly where it was, and the run does not
notice. The coordinator passes `cardPresent: visible`, not `cardPresent: tracked` — a locked card
is still a card you can play on, which is the entire reason the lock exists. Snails on a locked
model stay grabbable, so a hand across the card mid-grab costs nothing.

**Card lost, no hand.** The model hides, and the run enters `grace`:

- All the run's own clocks stop. `timeLeft` is untouched, and so is `score`.
- `graceLeft` counts down from `graceDuration` (5 s).
- The card coming back inside those 5 s returns the run to the phase it left — `countdown` or
  `playing` — with the same score and the same time remaining.
- The 5 s elapsing calls `reset()`: phase `idle`, score 0, clocks back to full. The next
  simulation card seen starts a completely fresh run.

The timer pausing rather than draining is deliberate. Losing the card is not the player's doing,
and a clock running down behind a screen they cannot see would read as a cheat.

## Why the coordinator drives it

`GameSession.update(cardPresent:now:)` is called from `onRenderFrame()`, alongside the pose filter,
for two reasons:

1. The render loop is already the one place per-frame work happens, and it is already `Cancellable`
   and already immune to the `ARFrame` retention trap — see "Render loop, not session delegate" in
   [tracking.md](tracking.md).
2. "On screen" is a question only the coordinator can answer. ARKit reports a locked card as *not
   tracked*, so anything reading `isAnchored` on its own would end a run at the moment a hand
   covers the card, which is precisely the case the lock was written to survive.

Elapsed time comes from `Date()` deltas rather than a frame count, because rendered frames are not
guaranteed to arrive at 60 fps and a run that lasts longer on a slower device would be a bug.

The clocks are `@ObservationIgnored`. They are written on every rendered frame and nothing draws
them — the overlays read the whole-second properties (`secondsRemaining`, `countdownNumber`,
`graceSecondsRemaining`), which are only written when the displayed value actually changes.
`@Observable` notifies on every set without comparing, so both halves of that matter.

## Scoring, and putting the pieces back

Both games score `+1` a piece and run on the same 30 s clock, but **they score at opposite ends of
the gesture**, and that is forced by what a grab means in each:

| | Scored at | Because |
|---|---|---|
| RemovingDrupella | the grab | a grabbed snail always ends up removed, so the grab commits it |
| PlantingCoral | the plant | a grabbed coral may never reach a plant point, so the grab commits nothing |

Everything else below is about the drupella case.

Score is `+1` per drupella snail picked off, counted in `attemptGrab(at:)` rather than on release.
A grabbed snail is committed the instant it is picked up — that is the moment the haptic fires —
which avoids the awkward case of a snail still in hand when the buzzer goes.

Grabbing is gated on `phase == .playing`. Instructions, countdown, grace and the result screen all
leave the model on camera, and pinching through any of them would otherwise score.

**Except when the grab immediately turns out to be a put-back.** `releaseHeld()` checks the snail's
distance from its `home` slot against `pinchSnapRadius`, and *also* that `phase` is still
`.playing` — the same gate `attemptGrab(at:)` itself requires. Both true: the snail glides home via
`Entity.move(to:relativeTo:duration:)`, `game.unscored()` reverses the point, and `removed` clears
so it is grabbable again. Either false — dropped further off, or the run ended mid-drag — and it
falls through to the ordinary release below, keeping the point. The phase re-check exists so an
undo can't land after the run it belongs to has already ended, mirroring why the grab itself needs
that same gate.

`GameSession.unscored()` mirrors `scored()` exactly: `guard phase == .playing, score > 0 else {
return }`, `score -= 1`. Symmetric guard, so a late or stale call can't under/overshoot either.

A snap-back release fires its own haptic — `UINotificationFeedbackGenerator.notificationOccurred
(.success)`, not another `.impact` intensity — so "put back, not collected" reads as its own kind
of event rather than a third shade of grab/release. See "Haptics" in
[interaction.md](interaction.md).

**Play Again needs the pieces back**, which is why a released snail is hidden rather than deleted:

```swift
private struct Grabbable {
    let entity: Entity
    let game: Minigame
    let model: Entity     // so a coral can only be planted on its own structure
    let home: Transform   // snail: where it loaded. coral: the stack slot it was given.
    var removed = false
    var stackIndex: Int?  // planting only; nil for a snail
}
```

`updateFading()` ends a fade with `isEnabled = false` instead of `removeFromParent()`, and
`restoreAll()` walks the array putting each entity back to `home`, clearing its
`OpacityComponent`, re-enabling it and clearing `removed`. `home` is a *local* transform, so
restoring it re-seats the snail on the coral wherever the coral currently is — dragging writes
world-space positions into that same local transform, which is exactly what this undoes.

`restoreAll()` also clears every `PlantPoint.filled`, or a second planting run would start with the
structure already full. And `stackIndex` deliberately **survives** a plant: `removed` is what takes a
coral out of the pile and out of `isOnTopOfItsStack(_:)`'s reckoning, so keeping the slot is what
lets the pile be rebuilt exactly for the next run.

Restoring is triggered by watching for a phase change, not from the buttons, because the buttons
live in SwiftUI and the entities live in `PinchInteraction`. Watched there rather than in the
coordinator — `PinchInteraction.update()` compares `game.phase` against its own `lastPhase` every
call, since restoring snails is pinch-side bookkeeping the coordinator has no other reason to know
about:

```swift
if (game.phase == .instructions && lastPhase != .instructions)
    || (game.phase == .countdown && lastPhase == .finished) {
    restoreAll()
}
```

Both tests look at where the phase came *from*, because resuming out of `grace` also lands in
`countdown` or `playing` — and that is the same run, snails and all, which must not be restored.

## One run at a time

The first simulation card tracked claims the session (`activeSimulationCard`) and holds it until
the run is wiped. A second simulation card entering frame is only a model: its own snails are in
the pool and grabbable, but it does not start a competing run, and it is not what `cardPresent`
is asked about.

Nothing in the app is built around more than one player, and a second `GameSession` would need a
second HUD to go with it. If that is ever wanted, the shape to reach for is a session per card
rather than a session that switches cards.

## The overlays

All in `ContentView.swift`, one branch of `runOverlay` per phase, over the same dimmed backdrop
except for the HUD — which deliberately has none, since that is the one screen where the coral has
to stay visible. See "Part 4" in [app-shell.md](app-shell.md).

The status panel is hidden during `countdown`, `playing` and `finished`, where it would sit on top
of the HUD. It is kept up for `grace` on purpose: *Hand in frame* with nothing locked is exactly
the reading needed when a model failed to hold, and the grace screen is the moment it failed.

Pinch pickup is only live during `playing` — `attemptGrab(at:)` is gated on `phase == .playing`,
so pinching through any other screen does nothing.
