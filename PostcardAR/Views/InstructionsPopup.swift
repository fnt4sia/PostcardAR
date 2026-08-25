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

    /// `false` for a popup dismissed by tapping the screen rather than a button — the showcase
    /// card's "tap to reveal information" intro, which has nothing to press *to* dismiss.
    var showsButton: Bool = true

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
            VStack(spacing: 15) {
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
            

            if showsButton {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(DesignTokens.Typography.button)
                        .foregroundStyle(DesignTokens.whiteText)
                        .fitsOneLine(minimumScale: 0.7)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(DesignTokens.secondaryBlue))
                        .overlay(Capsule().stroke(DesignTokens.buttonBorder, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 000000).ignoresSafeArea()
        InstructionsPopup(
            title: "THE SILENT KILLER",
            message: """
                Drupella snails are eating the coral! Pinch one with your thumb and finger to pull it off. \n
                
                """
        )
    }
}
