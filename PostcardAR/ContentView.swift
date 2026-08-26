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
            // DEBUG PANEL — off. To bring the diagnostics readout back, uncomment every block
            // tagged `DEBUG PANEL`: `grep -rn "DEBUG PANEL" PostcardAR` finds all of them, across
            // this file, `PostcardARView.swift`, `PinchInteraction.swift` and `QRCardIdentity.swift`.
            //
            // .overlay(alignment: .topTrailing) {
            //     if showsStatusPanel { statusPanel }
            // }
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
                            message: "Tap a blue dot to learn more.",
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

    // MARK: Diagnostics — DEBUG PANEL, commented out
    //
    // Developer UI: the top-right readout that answers "nothing appeared, which half failed?" by
    // reporting the two halves of card identity separately — ARKit tracking an image, and Vision
    // decoding a QR. A tracked card alone never summons a model, so "Detected" beside "No QR" is
    // the whole diagnosis. See docs/troubleshooting.md for what each line means.
    //
    // Commented out rather than deleted so it can come back. Restoring it is uncommenting every
    // block tagged `DEBUG PANEL` — `grep -rn "DEBUG PANEL" PostcardAR` lists them: this one, the
    // `.overlay` in `body` above, `ARStatus`'s fields and the per-frame gathering and writes in
    // `PostcardARView.swift`, `qrDecodeRate` in `PinchInteraction.swift`, and `decodeRate` in
    // `QRCardIdentity.swift`.
    //
    // **All five go together.** This panel was lost once by commenting out only its call site: the
    // view survived with no caller, and every `ARStatus` field feeding it went on being written
    // sixty times a second for nobody. Half-restoring it has the same failure mode in reverse.
    //
    // /// Hidden once a run is on screen, where it would sit on top of the HUD. Kept up for the grace
    // /// screen on purpose: "hand in frame" with nothing locked is exactly the reading needed when a
    // /// model failed to hold, and that is the moment it failed.
    // private var showsStatusPanel: Bool {
    //     switch game.phase {
    //     case .idle, .instructions, .grace: true
    //     case .countdown, .playing, .finished: false
    //     }
    // }
    //
    // /// Detection, identity and loading reported separately, because when nothing shows up the
    // /// question is always which of the three failed.
    // private var statusPanel: some View {
    //     VStack(alignment: .leading, spacing: 6) {
    //         line(!status.detectedImages.isEmpty,
    //              done: "Detected: \(status.detectedImages.joined(separator: ", "))",
    //              waiting: "Looking for a card…", icon: "viewfinder")
    //
    //         // The percentage is the point, not the name: a QR is checksummed, so a name is never
    //         // wrong, only absent or intermittent. A name arriving at 20% cannot carry a card.
    //         Label(status.qrPayload.map { "QR: \($0) · \(Int(status.qrDecodeRate * 100))%" }
    //                 ?? "No QR · \(Int(status.qrDecodeRate * 100))%",
    //               systemImage: status.qrPayload == nil ? "qrcode.viewfinder" : "qrcode")
    //             .foregroundStyle(status.qrPayload == nil ? .white.opacity(0.6) : Color.green)
    //
    //         // Tagged with the route that placed each one, so a card standing on its own reference
    //         // image can be told from one a payload bound — the two are indistinguishable on camera.
    //         if status.showingCards.isEmpty {
    //             Label("No model on screen", systemImage: "cube")
    //                 .foregroundStyle(.white.opacity(0.6))
    //         } else {
    //             Label("Showing: \(status.showingCards.joined(separator: ", "))",
    //                   systemImage: "cube.fill")
    //                 .foregroundStyle(Color.green)
    //         }
    //
    //         // Only while it is actually holding something. The lock is invisible when it works —
    //         // the model simply stays put — so this is what says it was the lock and not luck, and
    //         // the hand line below says whether Vision is seeing the hand at all.
    //         if !status.lockedCards.isEmpty {
    //             Label("Locked: \(status.lockedCards.joined(separator: ", "))",
    //                   systemImage: "lock.fill")
    //                 .foregroundStyle(.yellow)
    //         }
    //
    //         Label(status.handInFrame ? "Hand in frame" : "No hand",
    //               systemImage: status.handInFrame ? "hand.raised.fill" : "hand.raised.slash")
    //             .foregroundStyle(status.handInFrame ? Color.green : .white.opacity(0.6))
    //
    //         line(library.total > 0 && library.loaded == library.total,
    //              done: "Models loaded (\(library.loaded))",
    //              waiting: "Loading models (\(library.loaded)/\(library.total))…",
    //              icon: "clock")
    //
    //         ForEach(library.errors, id: \.self) { message in
    //             Text(message)
    //                 .font(.caption)
    //                 .foregroundStyle(.red)
    //         }
    //     }
    //     .font(.caption.weight(.medium))
    //     // Fixed, not a Dynamic Type token: this is a dense developer readout, and growing it with
    //     // the system text size only pushes lines off the card it is drawn on.
    //     .dynamicTypeSize(.medium)
    //     .foregroundStyle(.white)
    //     .padding(10)
    //     .frame(maxWidth: 260, alignment: .leading)
    //     .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
    //     .padding(8)
    //     // Never eats a tap: the one gesture in the app opens an annotation, and a dot can sit
    //     // anywhere on screen including under this.
    //     .allowsHitTesting(false)
    // }
    //
    // private func line(_ isDone: Bool, done: String, waiting: String, icon: String) -> some View {
    //     Label(isDone ? done : waiting, systemImage: isDone ? "checkmark.circle.fill" : icon)
    //         .foregroundStyle(isDone ? Color.green : .white)
    // }
    //
}

#Preview {
    ContentView()
}
