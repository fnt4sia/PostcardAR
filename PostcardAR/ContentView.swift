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
        Button("Start Scanning") {
            isScanning = true
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fullScreenCover(isPresented: $isScanning) {
            ScannerScreen()
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

    var body: some View {
        PostcardARView(status: status, game: game)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if showsStatusPanel { statusPanel }
            }
            .overlay(alignment: .bottom) {
                // The result screen carries its own Close, so it does not need this one too.
                if game.phase != .finished {
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
            }
            .overlay { runOverlay }
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
                VStack(spacing: 20) {
                    Text("Save the Coral")
                        .font(.largeTitle.bold())
                    Text("""
                        Drupella snails are eating this coral.
                        Pinch one with your thumb and finger to pull it off.
                        Clear as many as you can in 30 seconds.
                        """)
                        .multilineTextAlignment(.center)
                    Button("Start") { game.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 8)
                }
                .padding(32)
            }

        case .countdown:
            dimmed {
                Text("\(game.countdownNumber)")
                    .font(.system(size: 140, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: game.countdownNumber)
            }

        case .playing:
            ZStack {
                if status.handTooClose { tooCloseNotice }
                hud // above the blur, not under it — the score and clock stay readable.
            }
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
                VStack(spacing: 16) {
                    Text("Time's up")
                        .font(.largeTitle.bold())
                    Text("Score \(game.score)")
                        .font(.title.weight(.semibold).monospacedDigit())
                    Button("Play Again") { game.playAgain() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 8)
                    Button("Close") { dismiss() }
                }
                .padding(32)
            }
        }
    }

    /// Score left, clock right. No backdrop — this is the one screen where the coral has to stay
    /// visible, so the text carries a shadow instead of a panel.
    private var hud: some View {
        VStack {
            HStack {
                Label("\(game.score)", systemImage: "checkmark.seal.fill")
                Spacer()
                Label(String(format: "%02d", game.secondsRemaining), systemImage: "timer")
                    .foregroundStyle(game.secondsRemaining <= 5 ? Color.red : .white)
                    .contentTransition(.numericText(countsDown: true))
            }
            .font(.title2.weight(.bold).monospacedDigit())
            .animation(.snappy, value: game.secondsRemaining)
            .animation(.snappy, value: game.score)
            .padding(.horizontal, 24)
            Spacer()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 4)
        .padding(.top, 8)
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
