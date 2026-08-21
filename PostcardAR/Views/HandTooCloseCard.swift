//
//  HandTooCloseCard.swift
//  PostcardAR
//
//  Reproduces the Figma "put your hand further away" card — icon, title, message, no button or
//  number. Same InstructionsCardShape/layout numbers as InstructionsPopup and GraceCard (344×439
//  card, content column centered at cardHeight/2 + 7.49), since this is the same card family —
//  just no node id was pulled for this one (built from a pasted screenshot), so its icon is a
//  parameter rather than hardcoded: `icon` takes an SF Symbol name ("hand.raised" per the ask).
//
//  Wired into ContentView's tooCloseNotice, replacing its plain icon+text content — the outer
//  blur backdrop there is unchanged.
//

import SwiftUI

struct HandTooCloseCard: View {
    var icon: String
    var title: String
    var message: String

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
                .font(.system(size: 44))

            Text(title)
                .font(.custom("JetBrainsMono-Bold", size: 34))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.custom("InterVariable", size: 18))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(DesignTokens.whiteText)
    }
}

#Preview {
    ZStack {
        Color(hex: 0x081A49).ignoresSafeArea()
        HandTooCloseCard(
            icon: "hand.raised",
            title: "PUT YOUR HAND\nFURTHER AWAY",
            message: "Keep your whole hand on the camera view."
        )
    }
}
