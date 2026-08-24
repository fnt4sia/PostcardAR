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
            // system slide, not something SwiftUI lets you restyle. This crossfades instead, like
            // every other panel in the app (`dimmed()`, the phase-to-phase run UI).
            if isScanning {
                Group {
                    if library.isReady {
                        ScannerScreen(library: library, close: { isScanning = false })
                    } else {
                        LoadingView(loaded: library.loaded, total: library.total)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isScanning)
    }
}

/// The camera, full screen, with a status panel and — on a Simulation card — the run's UI over it.
///
/// `status` and `game` are created here and handed down. They are the only channels out of the AR
/// view: the coordinator writes to them, and reading a property in `body` is what subscribes this
/// view to changes in that property. `game` also flows the other way, since Start and Play Again
/// are buttons; the coordinator notices those by watching the phase change, not by being called.
private struct ScannerScreen: View {
    /// Loaded before this screen was built — see `ModelLibrary`.
    let library: ModelLibrary

    /// Replaces `@Environment(\.dismiss)` — that only exists inside a real presentation
    /// (`.sheet`/`.fullScreenCover`), and this screen is a plain conditional now. See `ContentView`.
    let close: () -> Void

    @State private var status = ARStatus()
    @State private var game = GameSession()
    @State private var annotations = AnnotationLayer()

    var body: some View {
        PostcardARView(status: status, game: game, annotations: annotations, library: library)
            .ignoresSafeArea()
            // No annotation overlay: the labels are entities in the scene now, drawn by RealityKit
            // rather than by SwiftUI. See `Annotations.swift`.
            .overlay(alignment: .topLeading) {
                // Hidden on .countdown too — 3·2·1 shouldn't be interruptible any more than the
                // result screen is.
                if game.phase != .finished && game.phase != .countdown {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "x.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .secondaryBlue.opacity(1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding()
                }
            }
            .overlay { runOverlay }
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
                PlayingHintBar(text: "PINCH & HOLD TO REMOVE")
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

    // MARK: Status

    /// Hidden once a run is on screen, where it would sit on top of the HUD. Kept up for the
    /// grace screen on purpose: "hand in frame" with nothing locked is exactly the reading needed
    /// when a model failed to hold, and that is the moment it failed.
    private var showsStatusPanel: Bool {
        switch game.phase {
        case .idle, .instructions, .grace: true
        case .countdown, .playing, .finished: false
        }
    }

    /// Detection and model loading are reported separately, because when nothing shows up the
    /// question is always which of the two failed. Both are counts now that the group can hold
    /// several cards: which ones are on camera, and how many of their models have arrived.
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(!status.detectedImages.isEmpty,
                 done: "Detected: \(status.detectedImages.joined(separator: ", "))",
                 waiting: "Looking for a card…", icon: "viewfinder")

            // Only while it is actually holding something. The lock is invisible when it works
            // — the model simply stays put — so this is what says it was the lock and not luck,
            // and the hand icon says whether Vision is seeing the hand at all.
            if !status.lockedImages.isEmpty {
                Label("Locked: \(status.lockedImages.joined(separator: ", "))",
                      systemImage: "lock.fill")
                    .foregroundStyle(.yellow)
            }

            Label(status.handInFrame ? "Hand in frame" : "No hand",
                  systemImage: status.handInFrame ? "hand.raised.fill" : "hand.raised.slash")
                .foregroundStyle(status.handInFrame ? Color.green : .white.opacity(0.6))

            line(status.totalImages > 0 && status.loadedModels == status.totalImages,
                 done: "Models loaded (\(status.loadedModels))",
                 waiting: "Loading models (\(status.loadedModels)/\(status.totalImages))…",
                 icon: "clock")

            ForEach(status.errors, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
        .padding()
    }

    private func line(_ isDone: Bool, done: String, waiting: String, icon: String) -> some View {
        Label(isDone ? done : waiting, systemImage: isDone ? "checkmark.circle.fill" : icon)
            .foregroundStyle(isDone ? Color.green : .white)
    }
}

#Preview {
    ContentView()
}
