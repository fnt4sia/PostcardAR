//
//  GraceCard.swift
//  PostcardAR
//

import SwiftUI

struct GraceCard: View {
    var title: String
    var message: String
    var secondsRemaining: Int

    @State private var pulsed = false

    /// Grows with the text beside it — see the note at the icon.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44

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
                // `@ScaledMetric` rather than a `Font` token: `Font.system(size:)` is genuinely
                // fixed, so an SF Symbol sized that way is the one thing on the card that would
                // not grow with the words beside it.
                .font(.system(size: iconSize))
                .symbolEffect(.pulse)
                .foregroundStyle(DesignTokens.blueText)

            Text(title)
                .font(DesignTokens.Typography.panelTitle)
                .fitsBlock()
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.whiteText)

            Text(message)
                .font(DesignTokens.Typography.body)
                .fitsBlock()
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.blueText)

            Text("\(secondsRemaining)")
                .font(DesignTokens.Typography.graceValue)
                .fitsOneLine(minimumScale: 0.5)
                .contentTransition(.numericText(countsDown: true))
                .scaleEffect(pulsed ? 1.15 : 1)
                .animation(.snappy, value: secondsRemaining)
                .animation(.spring(response: 0.2, dampingFraction: 0.4), value: pulsed)
                .frame(width: 266.444)
                .foregroundStyle(DesignTokens.whiteText)
        }
        .onChange(of: secondsRemaining) {
            pulsed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pulsed = false }
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 00000).ignoresSafeArea()
        GraceCard(
            title: "POINT AT THE CARD AGAIN",
            message: "Your score and time are held until this reaches zero.",
            secondsRemaining: 3
        )
    }
}
