//
//  CountdownCard.swift
//  PostcardAR
//

import SwiftUI

struct CountdownCard: View {
    var text: String
    @State private var pulsed = false

    private let cardSize = CGSize(width: 282.099, height: 360.018)

    private var fontSize: CGFloat {
        text == "START!" ? 70 : 164.711
    }
    
    private var offsetY: CGFloat {
        text == "START!" ? 140 : 71
    }

    var body: some View {
        ZStack(alignment: .top) {
            Image("CountdownCardShape")
                .resizable()
                .frame(width: cardSize.width, height: cardSize.height)

            Text(text)
                .font(DesignTokens.Typography.countdownValue(size: fontSize))
                // "START!" is six characters at 70pt in a 266pt box — it is already close, and
                // one Dynamic Type step puts it over. The digits have room to spare; this costs
                // them nothing.
                .fitsOneLine(minimumScale: 0.5)
                .foregroundStyle(DesignTokens.whiteText)
                .contentTransition(.numericText(countsDown: true))
                .scaleEffect(pulsed ? 1.15 : 1)
                .animation(.snappy, value: text)
                .animation(.spring(response: 0.2, dampingFraction: 0.4), value: pulsed)
                .frame(width: 266.444)
                .offset(y: offsetY)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .onChange(of: text) {
            pulsed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pulsed = false }
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 000000).ignoresSafeArea()
        CountdownCard(text: "START!")
    }
}
