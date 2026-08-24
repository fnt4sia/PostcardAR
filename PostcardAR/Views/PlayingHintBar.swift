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
                .font(.custom("JetBrainsMono-Regular", size: 20))
                .foregroundStyle(DesignTokens.whiteText)
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
