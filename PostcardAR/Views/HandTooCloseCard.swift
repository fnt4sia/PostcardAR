//
//  HandTooCloseCard.swift
//  PostcardAR
//

import SwiftUI

struct HandTooCloseCard: View {
    var icon: String
    var title: String
    var message: String

    /// Grows with the text beside it — see `GraceCard`, which sizes its icon the same way.
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
            Image(systemName: icon)
                .font(.system(size: iconSize))
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
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 00000).ignoresSafeArea()
        HandTooCloseCard(
            icon: "hand.raised",
            title: "PUT YOUR HAND\nFURTHER AWAY",
            message: "Keep your whole hand on the camera view."
        )
    }
}
