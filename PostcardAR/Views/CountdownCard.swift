//
//  CountdownCard.swift
//  PostcardAR
//


import SwiftUI

struct CountdownCard: View {
    var number: Int
    @State private var pulsed = false

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
                .scaleEffect(pulsed ? 1.15 : 1)
                .animation(.snappy, value: number)
                .animation(.spring(response: 0.2, dampingFraction: 0.4), value: pulsed)
                .frame(width: 266.444)
                .offset(y: 71)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .onChange(of: number) {
            pulsed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pulsed = false }
        }
    }
}

#Preview {
    ZStack {
        Color(hex: 000000).ignoresSafeArea()
        CountdownCard(number: 3)
    }
}
