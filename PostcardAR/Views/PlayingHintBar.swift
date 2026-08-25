//
//  PlayingHintBar.swift
//  PostcardAR
//

import SwiftUI

struct PlayingHintBar: View {
    var text: String

    /// Which background this bar draws on — `.pinch` for every simulation hint, `.tap` for the
    /// showcase-card "TAP ON SCREEN" hint, which reads as two full lines and needs the taller
    /// shape to hold them. Same 344pt width either way; only the height differs.
    enum Shape {
        case pinch
        case tap

        var imageName: String {
            switch self {
            case .pinch: "PinchHintShape"
            case .tap: "TapHintShape"
            }
        }

        var height: CGFloat {
            switch self {
            case .pinch: 69.018
            case .tap: 99
            }
        }
    }

    var shape: Shape = .pinch

    private var size: CGSize { CGSize(width: 344, height: shape.height) }

    var body: some View {
        ZStack {
            Image(shape.imageName)
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
