//
//  ContentView.swift
//  PostcardAR
//
//  Created by Fitra Ramadhan on 15/08/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isScanning = false

    var body: some View {
        HomeView(action: { isScanning = true })
            .fullScreenCover(isPresented: $isScanning) {
                ScannerScreen()
                    .onDisappear { isScanning = false }
            }
    }
}

/// The camera, full screen, with a status panel and — on a Simulation card — the run's UI over it.
///
/// `status` and `game` are created here and handed down. They are the only channels out of the AR
/// view: the coordinator writes to them, and reading a property in `body` is what subscribes this
/// view to changes in that property. `game` also flows the other way, since Start and Play Again
/// are buttons; the coordinator notices those by watching the phase change, not by being called.
private struct ScannerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = ARStatus()
    @State private var game = GameSession()
    @State private var annotations = AnnotationLayer()

    var body: some View {
        PostcardARView(status: status, game: game, annotations: annotations)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) { annotationLayer }

            .overlay(alignment: .topLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "x.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding()
            }
            .overlay { runOverlay }
    }

    // MARK: Annotations

    /// The explanation labels, each at the screen point its `Annotation*` entity projects to.
    ///
    /// Aligned `.topLeading` because `.position(_:)` is measured from its container's origin, and
    /// that container has to be the same rectangle `arView.project(_:)` reported into — which it is,
    /// since `PostcardARView` fills the screen and ignores the safe area.
    ///
    /// Card and dot are positioned separately: `.position(_:)` centres a view, so anchoring the
    /// bottom of a card-plus-stem stack on the point would need a height that depends on how far
    /// the body text wraps. See `AnnotationBox`.
    private var annotationLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(annotations.placed) { placed in
                AnnotationDot()
                    .position(placed.point)
                AnnotationBox(title: placed.title, detail: placed.detail)
                    .position(x: placed.point.x, y: placed.point.y - AnnotationBox.offset)
            }
        }
        .allowsHitTesting(false) // labels are read, not tapped — never swallow the Close button
    }

    // MARK: The run

    /// Instructions, countdown, HUD, grace, result — one per phase, and nothing on a showcase card.
    @ViewBuilder
    private var runOverlay: some View {
        switch game.phase {
        case .idle:
            EmptyView()

        case .instructions:
            dimmed {
                InstructionsPopup(
                    title: "THE SILENT KILLER",
                    message: """
                        Drupella snails are eating the coral! Pinch one with your thumb and finger to pull it off.
                        Clear as many as you can in 30 seconds.
                        """,
                    action: { game.start() }
                )
            }

        case .countdown:
            dimmed {
                CountdownCard(number: game.countdownNumber)
            }

        case .playing:
            ZStack(alignment: .top) {
                if status.handTooClose { tooCloseNotice }
            
                TimerHUD(secondsRemaining: game.secondsRemaining, current: game.score, total: 8)
                    .padding(.top, 50)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.2), value: status.handTooClose)

        case .grace:
            dimmed {
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 44))
                    Text("Point at the card again")
                        .font(.title3.weight(.semibold))
                    Text("\(game.graceSecondsRemaining)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: game.graceSecondsRemaining)
                    Text("Your score and time are held until this reaches zero.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(32)
            }

        case .finished:
            dimmed {
                FinishScreen(
                    label: "CLEARED",
                    value: "\(game.score)",
                    title: "DRUPELLA REMOVED",
                    buttonTitle: "Play Again",
                    action: { game.playAgain() }
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
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 44))
                    Text("Move your hand back")
                        .font(.title3.weight(.semibold))
                    Text("Keep your whole hand in the camera's view.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .padding(32)
            }
            .transition(.opacity)
    }

    /// Every full-screen run panel sits on the same dimmed backdrop.
    private func dimmed(@ViewBuilder content: () -> some View) -> some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
            content()
        }
        .foregroundStyle(.white)
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
