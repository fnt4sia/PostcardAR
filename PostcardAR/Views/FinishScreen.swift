//
//  FinishScreen.swift
//  PostcardAR
//
//  Reproduces the Figma finish card (node 310:2286) — same FinishCardShape as before (byte-
//  identical asset, unchanged), but the single button became two: a small circular restart icon
//  and a "Finish Activity" pill, per the redesign. Mapped per the actual gameplay meaning rather
//  than Figma's literal icon (its own annotation guessed SF Symbol "memories", not a real match
//  for the restart-arrow glyph in the mockup) — restartIcon plays the run again, finishAction
//  goes back to Home.
//

import SwiftUI

struct FinishScreen: View {
    var label: String
    var value: String
    var title: String
    var restartAction: () -> Void = {}
    var finishButtonTitle: String = "Finish Activity"
    var finishAction: () -> Void = {}

    private let cardSize = CGSize(width: 344, height: 439.018)

    var body: some View {
        ZStack(alignment: .top) {
            Image("FinishCardShape")
                .resizable()
                .frame(width: cardSize.width, height: cardSize.height)

            VStack(spacing: 15) {
                VStack(spacing: 0.5) {
                    Text(label)
                        .font(.custom("JetBrainsMono-Regular", size: 18))
                        .foregroundStyle(Color(hex: 0x585757))

                    Text(value)
                        .font(.custom("JetBrainsMono-Bold", size: 72))
                        .foregroundStyle(DesignTokens.progressGradient)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: value)

                    Text(title)
                        .font(.custom("JetBrainsMono-Bold", size: 28))
                        .foregroundStyle(DesignTokens.blackText)
                        .padding(.top, 8)
                }

                HStack(spacing: 8) {
                    Button(action: restartAction) {
                        Circle()
                            .fill(DesignTokens.secondaryBlue)
                            .overlay(Circle().stroke(DesignTokens.progressGradient, lineWidth: 1))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundStyle(DesignTokens.whiteText)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button(action: finishAction) {
                        Text(finishButtonTitle)
                            .font(.custom("InterVariable", size: 18))
                            .foregroundStyle(DesignTokens.whiteText)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(Capsule().fill(DesignTokens.secondaryBlue))
                            .overlay(Capsule().stroke(DesignTokens.buttonBorder, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .multilineTextAlignment(.center)
            .padding(.top, 108)
        }
        .frame(width: cardSize.width, height: cardSize.height)
    }
}

#Preview {
    ZStack {
        Color(hex: 0x081A49).ignoresSafeArea()
        FinishScreen(label: "CLEARED", value: "8", title: "DRUPELLA REMOVED")
    }
}
