//
//  ContentView.swift
//  PostcardAR
//
//  Created by Fitra Ramadhan on 15/08/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var isScanning = false

    /// Owned here, *above* the `fullScreenCover`, so it outlives the camera screen. That is the
    /// whole cache: dismissing the scanner tears down its `Coordinator` and its `ARView`, and the
    /// library — reference images and models both — survives to be reused by the next scan.
    @State private var library = ModelLibrary()

    var body: some View {
        ZStack {
            HomeView(action: {
                isScanning = true
                // Returns immediately once the library is loaded, which is why only the first scan
                // of a launch ever sees `LoadingView`.
                Task { await library.load() }
            })

            // A plain conditional instead of `.fullScreenCover`: a cover's dismissal is a fixed
            // system slide, not something SwiftUI lets you restyle. Crossfades in; on the way out
            // it also recedes slightly, the same `.scale.combined(with: .opacity)` the `.finished`
            // result card itself already uses — so leaving reads as the same kind of motion as
            // arriving there did, not a mirror-image slide.
            if isScanning {
                Group {
                    if library.isReady {
                        ScannerScreen(library: library, close: { isScanning = false })
                    } else {
                        LoadingView(loaded: library.loaded, total: library.total)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.92).combined(with: .opacity)
                ))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isScanning)
        // The one place Dynamic Type is capped, for the whole app. Every screen below — including
        // the run's overlays over the camera — inherits it through the environment. See
        // `DesignTokens.maximumDynamicTypeSize`.
        .accessibleLayout()
    }
}

/// The camera, full screen, with the run's UI over it on a Simulation card.
///
/// `status` and `game` are the only channels out of the AR view: the coordinator writes to them,
/// and reading one in `body` is what subscribes this view. `game` also flows back, since Start and
/// Play Again are buttons — the coordinator watches the phase rather than being called.
private struct ScannerScreen: View {
    /// Loaded before this screen was built — see `ModelLibrary`.
    let library: ModelLibrary

    /// Replaces `@Environment(\.dismiss)` — that only exists inside a real presentation
    /// (`.sheet`/`.fullScreenCover`), and this screen is a plain conditional now. See `ContentView`.
    let close: () -> Void

    /// The close button grows with the system text size like everything else, but it sits over the
    /// camera rather than inside a traced card, so it has room to.
    @ScaledMetric(relativeTo: .title) private var closeButtonSize: CGFloat = 34

    @State private var status = ARStatus()
    @State private var game = GameSession()
    @State private var annotations = AnnotationLayer()

    /// Whether the showcase card's own intro has been dismissed for the *current* sighting of an
    /// annotated card. Reset to `false` when `annotatedShowcaseVisible` drops, so scanning the
    /// card again shows the intro again rather than remembering it was dismissed once and never
    /// speaking again for the rest of the session.
    @State private var dismissedAnnotationIntro = false

    /// Single source of truth for the intro popup, shared by the popup itself and the X button
    /// that must hide while it's up — two separate `if`s reading the same three conditions would
    /// have been exactly the kind of drift that let the X button show over it in the first place.
    private var showsAnnotationIntro: Bool {
        status.annotatedShowcaseVisible && !dismissedAnnotationIntro && game.phase == .idle
    }

    var body: some View {
        PostcardARView(status: status, game: game, annotations: annotations, library: library)
            .ignoresSafeArea()
            // No annotation overlay: the labels are entities in the scene now, drawn by RealityKit
            // rather than by SwiftUI. See `Annotations.swift`.
            .overlay(alignment: .topLeading) {
                // Hidden on .countdown too — 3·2·1 shouldn't be interruptible any more than the
                // result screen is.
                if game.phase != .finished && game.phase != .countdown && !showsAnnotationIntro {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "x.circle.fill")
                            .font(.system(size: closeButtonSize))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .secondaryBlue.opacity(1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding()
                }
            }
            .overlay { runOverlay }
            // A showcase card's own hint, for tapping its labels open. Gated on `.idle`: a
            // simulation card already owns the bottom of the screen the moment a run starts
            // (its own `PlayingHintBar`, the HUD, the result card), and two cards can be in
            // frame together — this only speaks while nothing else is.
            .overlay(alignment: .bottom) {
                // Waits for the intro to be dismissed first — otherwise the hint bar and the
                // popup telling the player the exact same thing were showing at once.
                if status.annotatedShowcaseVisible, dismissedAnnotationIntro, game.phase == .idle {
                    PlayingHintBar(text: "TAP ON SCREEN\nFOR INFORMATION", shape: .tap)
                        .padding(.bottom, 37)
                }
            }
            // The showcase card's intro, once per sighting. No button — tapping anywhere, dot or
            // not, dismisses it; the dimmed backdrop itself catches that tap before it can reach
            // a dot underneath, so the first tap only ever closes the intro, never also opens a
            // label on the same gesture.
            .overlay {
                if showsAnnotationIntro {
                    dimmed {
                        InstructionsPopup(
                            title: "TAP ON YOUR SCREEN\nTO REVEAL INFORMATION",
                            message: "Tap a white dot to learn more.",
                            showsButton: false
                        )
                    }
                    .onTapGesture { dismissedAnnotationIntro = true }
                }
            }
            .onChange(of: status.annotatedShowcaseVisible) { _, visible in
                if !visible { dismissedAnnotationIntro = false }
            }
            // Phase-keyed haptics, independent of the per-second ones below: a "get ready" tap
            // right at countdown kickoff (before 3 even shows — the text-keyed haptic only fires
            // on a *change*, so a countdownText already "3" from its default would otherwise skip
            // that first beat), and a success tap the instant the result card appears.
            .onChange(of: game.phase) { _, phase in
                switch phase {
                case .countdown: UIImpactFeedbackGenerator(style: .light).impactOccurred()
                case .finished: UINotificationFeedbackGenerator().notificationOccurred(.success)
                default: break
                }
            }
            // A light tap on each of 3·2·1, a stronger one on "START!" — same asymmetry as the Camera app's own self-timer.
            .onChange(of: game.countdownText) { _, text in
                if text == "START!" {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }

    // MARK: The run

    /// Instructions, countdown, HUD, grace, result — one per phase, and nothing on a showcase card.
    ///
    /// Every word and number that differs between the two minigames is read off the run rather than
    /// written here: the copy from `game.minigame.settings` (see `Minigame.swift`) and the goal from
    /// `game.target`, which the model itself supplied. Nothing in this file knows which game is on.
    @ViewBuilder
    private var runOverlay: some View {
        switch game.phase {
        case .idle:
            EmptyView()

        case .instructions:
            dimmed {
                InstructionsPopup(
                    title: game.minigame.settings.title,
                    message: game.minigame.settings.instructions,
                    action: { game.start() }
                )
            }

        case .countdown:
            dimmed {
                CountdownCard(text: game.countdownText)
            }

        case .playing:
            ZStack(alignment: .top) {
                if status.handTooClose { tooCloseNotice }

                TimerHUD(secondsRemaining: game.secondsRemaining, current: game.score, total: game.target)
                    .padding(.top, 50)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                PlayingHintBar(text: game.minigame.settings.hint)
                    .padding(.bottom, 37)
            }
            .animation(.easeInOut(duration: 0.2), value: status.handTooClose)

        case .grace:
            dimmed {
                GraceCard(
                    title: "POINT AT THE CARD AGAIN",
                    message: "Your score and time are held until this reaches zero.",
                    secondsRemaining: game.graceSecondsRemaining
                )
            }

        case .finished:
            dimmed {
                FinishScreen(
                    label: game.minigame.settings.resultLabel,
                    value: "\(game.score)",
                    title: game.minigame.settings.resultTitle,
                    restartAction: { game.playAgain() },
                    finishAction: { close() }
                )
            }
        }
    }

    /// Blurs the camera and says why, while a hand is in frame that Vision cannot read a pinch
    /// from — nearly always a hand held too close to the lens. See `PinchInteraction.handTooClose`.
    ///
    /// Only on `playing`, because that is the one phase where a pinch is meant to do something,
    /// so it is the only one where failing to read a pinch needs explaining. A blur is the right
    /// shape for it: the failure is that the camera cannot make the hand out, and the screen
    /// going soft says that without a modal panel over a game the player is mid-way through.
    private var tooCloseNotice: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .overlay {
                HandTooCloseCard(
                    icon: "hand.raised",
                    title: "PUT YOUR HAND\nFURTHER AWAY",
                    message: "Keep your whole hand on the camera view."
                )
            }
            .transition(.opacity)
    }

    /// Every full-screen run panel sits on the same dimmed backdrop.
    private func dimmed(@ViewBuilder content: () -> some View) -> some View {
        ZStack {
            // Its own .opacity-only transition — never .scale. A scale transition applies a
            // geometric transform to the whole already-laid-out subtree, and this rectangle is
            // full-bleed (.ignoresSafeArea()), so scaling it shrinks the entire black backdrop
            // toward its center mid-animation, briefly exposing the camera at the edges. That was
            // the "black overlay glitches and becomes too small" bug — the backdrop was caught in
            // the same scale meant only for the card.
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .transition(.opacity)
            content()
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .foregroundStyle(.white)
        // Scoped here, not at the top of ScannerScreen.body: an .animation(value:) that high
        // wraps every button underneath — including the X button's own press-state — in one
        // ambient spring transaction, which is what made Start need a second tap to register.
        // Keeping it local to this helper means only a dimmed() panel's own appear/disappear
        // animates; nothing else's gestures get caught in it.
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: game.phase)
    }
}

#Preview {
    ContentView()
}
