//
//  FinishScreen.swift
//  PostcardAR
//

import SwiftUI

struct FinishScreen: View {
    var label: String
    var value: String
    var title: String
    var buttonTitle: String = "Scan another card"
    var action: () -> Void = {}

    private let cardSize = CGSize(width: 344, height: 439.018)

    var body: some View {
        ZStack(alignment: .top) {
            Image("FinishCardShape")
                .resizable()
                .frame(width: cardSize.width, height: cardSize.height)

            VStack(spacing: 8) {
                Text(label)
                    .font(.custom("JetBrainsMono-Regular", size: 18))
                    .foregroundStyle(Color(hex: 0x585757))

                Text(value)
                    .font(.custom("JetBrainsMono-Bold", size: 50))
                    .foregroundStyle(DesignTokens.progressGradient)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)

                Text(title)
                    .font(.custom("JetBrainsMono-Bold", size: 28))
                    .foregroundStyle(DesignTokens.blackText)
                    .padding(.top, 8)

                Button(buttonTitle, action: action)
                    .font(.custom("InterVariable", size: 18))
                    .foregroundStyle(DesignTokens.whiteText)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(Capsule().fill(DesignTokens.secondaryBlue))
                    .overlay(Capsule().stroke(DesignTokens.buttonBorder, lineWidth: 1))
                    .buttonStyle(PressableButtonStyle())
                    .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 117)
        }
        .frame(width: cardSize.width, height: cardSize.height)
    }
}

#Preview {
    ZStack {
        Color(hex: 0x081A49).ignoresSafeArea()
        FinishScreen(label: "CLEARED", value: "8/8", title: "DRUPELLA REMOVED")
    }
}
