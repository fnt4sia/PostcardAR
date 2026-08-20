# Simulation cards and the run

A card is one of two kinds, and the kind is the front of its name:

| Kind | Prefix | What it does |
|---|---|---|
| **Showcase** | anything else | Stands its model up to be looked at. Model appears while the card is tracked and hides when it is not. No lock, no pinch, no UI. |
| **Simulation** | `Simulation` | A minigame runs on it. The occlusion lock may hold its model on screen under a hand, its `Drupella*` entities are grabbable, and detecting it starts a run. |

```swift
private let simulationCardPrefix = "Simulation"
...
kind: name.hasPrefix(simulationCardPrefix) ? .simulation : .showcase
```

The type travels in the name for the same reason the model does: adding a card stays two files
and no code change, and nothing in the source names an individual card. It is the same idiom as
the `Drupella` prefix that `PinchInteraction.collectSnails(from:)` matches on. `Showcase` as a
prefix is a convention for readability only — the code tests for `Simulation` and treats
everything else as showcase, so an unprefixed card is a showcase card.

Renaming a card to change its kind means renaming its `.usdz` too; the pairing is still by exact
name. See [reference-images.md](reference-images.md) and [models.md](models.md).

## What the two kinds actually differ in

Three things, and nothing else:

| | Showcase | Simulation |
|---|---|---|
| Occlusion lock | never — hides the instant its card is lost | holds the model under a hand, per [tracking.md](tracking.md) |
| `Drupella*` entities collected into the grabbable pool | no | yes |
| Seeing the card starts a `GameSession` | no | yes |

The lock is a simulation-only feature because of what it is *for*. It exists so that reaching into
the scene does not delete the thing you are reaching for — a hand across the card is both the
ordinary way ARKit loses the card and the exact moment the player is grabbing a snail. A showcase
card has nothing to reach for, so a hand passing over it has no reason to keep a model frozen in
mid-air after the card has gone.

Showcase models never enter `snails`, which is the whole implementation of "no pinch on a showcase
card" — `attemptGrab(at:)` has nothing to find on one, with no extra test.

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

## Scoring, and putting the snails back

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

**Play Again needs the snails back**, which is why a released snail is hidden rather than deleted:

```swift
private struct Snail {
    let entity: Entity
    let home: Transform   // local transform at load time
    var removed = false
}
```

`updateFading()` ends a fade with `isEnabled = false` instead of `removeFromParent()`, and
`restoreAll()` walks the array putting each entity back to `home`, clearing its
`OpacityComponent`, re-enabling it and clearing `removed`. `home` is a *local* transform, so
restoring it re-seats the snail on the coral wherever the coral currently is — dragging writes
world-space positions into that same local transform, which is exactly what this undoes.

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
