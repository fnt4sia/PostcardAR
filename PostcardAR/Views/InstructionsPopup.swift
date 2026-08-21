//
//  InstructionsPopup.swift
//  PostcardAR
//


import SwiftUI

struct InstructionsPopup: View {
    var title: String
    var message: String
    var buttonTitle: String = "Start"
    var action: () -> Void = {}

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
        VStack(spacing: 24) {
            VStack(spacing: 18) {
                Text(title)
                    .font(.custom("JetBrainsMono-Bold", size: 34))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.custom("InterVariable", size: 18))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(DesignTokens.whiteText)

            Button(buttonTitle, action: action)
                .font(.custom("InterVariable", size: 18))
                .foregroundStyle(DesignTokens.whiteText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(DesignTokens.secondaryBlue))
                .overlay(Capsule().stroke(DesignTokens.buttonBorder, lineWidth: 1))
                .buttonStyle(PressableButtonStyle())
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 000000).ignoresSafeArea()
        InstructionsPopup(
            title: "THE SILENT KILLER",
            message: """
                Drupella snails are eating the coral! Pinch one with your thumb and finger to pull it off.
                Clear as many as you can in 30 seconds.
                """
        )
    }
}
