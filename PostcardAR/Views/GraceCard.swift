//
//  GraceCard.swift
//  PostcardAR
//
//  Reproduces the Figma "point at the card again" popup (node 380:153) — shown when a run's
//  card is lost mid-play and GameSession.graceSecondsRemaining is counting down. Wired into
//  ContentView's `.grace` case.
//
//  Card is InstructionsCardShape reused as-is: byte-identical geometry/opacity/gradient to
//  node 362:8's card, only Figma's internal IDs differ — not worth a second asset for the same
//  shape. The corner-bracket icon in Figma is eight tiny rotated rounded rects; that's exactly
//  SF Symbol "viewfinder", which the app's own placeholder for this phase already used natively.
//

import SwiftUI

struct GraceCard: View {
    var title: String
    var message: String
    var secondsRemaining: Int

    // Same pulse-on-change treatment as CountdownCard, since this is the same kind of
    // once-a-second countdown digit, just smaller.
    @State private var pulsed = false

    private let cardSize = CGSize(width: 344, height: 439.018)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("InstructionsCardShape")
                .resizable()
                .frame(width: cardSize.width, height: cardSize.height)

            content
                .frame(width: 266)
                .position(x: 39 + 266 / 2, y: cardSize.height / 2 + 7.49)
        }
        .frame(width: cardSize.width, height: cardSize.height)
    }

    private var content: some View {
        VStack(spacing: 15) {
            Image(systemName: "viewfinder")
                .font(.system(size: 44))
                .symbolEffect(.pulse)

            Text(title)
                .font(.custom("JetBrainsMono-Bold", size: 34))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.custom("InterVariable", size: 18))
                .multilineTextAlignment(.center)

            Text("\(secondsRemaining)")
                .font(.custom("JetBrainsMono-Bold", size: 60))
                .contentTransition(.numericText(countsDown: true))
                .scaleEffect(pulsed ? 1.15 : 1)
                .animation(.snappy, value: secondsRemaining)
                .animation(.spring(response: 0.2, dampingFraction: 0.4), value: pulsed)
                .frame(width: 266.444)
        }
        .foregroundStyle(DesignTokens.whiteText)
        .onChange(of: secondsRemaining) {
            pulsed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pulsed = false }
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 0x081A49).ignoresSafeArea()
        GraceCard(
            title: "POINT AT THE CARD AGAIN",
            message: "Your score and time are held until this reaches zero.",
            secondsRemaining: 3
        )
    }
}
