//
//  CountdownCard.swift
//  PostcardAR
//


import SwiftUI

struct CountdownCard: View {
    var number: Int
    private let fontsRegistered = DesignTokens.fontsRegistered

    private let cardSize = CGSize(width: 282.099, height: 360.018)

    var body: some View {
        ZStack(alignment: .top) {
            Image("CountdownCardShape")
                .resizable()
                .frame(width: cardSize.width, height: cardSize.height)

            Text("\(number)")
                .font(.custom("JetBrainsMono-Bold", size: 164.711))
                .foregroundStyle(DesignTokens.whiteText)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: number)
                .frame(width: 266.444)
                .offset(y: 71)
        }
        .frame(width: cardSize.width, height: cardSize.height)
    }
}

#Preview {
    ZStack {
        Color(hex: 000000).ignoresSafeArea()
        CountdownCard(number: 3)
    }
}
