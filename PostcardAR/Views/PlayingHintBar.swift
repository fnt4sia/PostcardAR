//
//  PlayingHintBar.swift
//  PostcardAR
//

import SwiftUI

struct PlayingHintBar: View {
    var text: String

    private let size = CGSize(width: 344, height: 69.018)

    var body: some View {
        ZStack {
            Image("PinchHintShape")
                .resizable()
                .frame(width: size.width, height: size.height)

            Text(text)
                .font(DesignTokens.Typography.hint)
                .foregroundStyle(DesignTokens.whiteText)
                // The bar is a fixed-size image, so the hint has to give rather than wrap out of
                // it. Two lines, because the longest hint is a full sentence.
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .offset(y: 8)
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview {
    ZStack {
        Color(hex: 0x081A49).ignoresSafeArea()
        PlayingHintBar(text: "PINCH & HOLD TO REMOVE")
    }
}
