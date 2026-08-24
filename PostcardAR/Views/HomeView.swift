//
//  HomeView.swift
//  PostcardAR
//

import SwiftUI

struct HomeView: View {
    var action: () -> Void = {}

    private let background = Color(hex: 0x081A49)

    /// How much room the headline may take, against the card's own 344pt width.
    private let headlineWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background.ignoresSafeArea()

                Image("HomeGridTop")
                    .resizable()
                    .frame(width: 435.469, height: 435)
                    .scaleEffect(x: -1, y: 1)
                    .offset(x: 105, y: -61)

                Image("HomeGridBottom")
                    .resizable()
                    .frame(width: 435.469, height: 435)
                    .offset(x: -136, y: 504)

                Image("CardShape")
                    .resizable()
                    .frame(width: 344, height: 439.018)
                    .offset(x: 29, y: 217)

                content
                    .frame(width: 239.304)
                    .position(x: 81.79 + 239.304 / 2, y: proxy.size.height / 2)
            }
        }
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("CORALIZE")
                    .font(DesignTokens.Typography.homeTitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
                    // One line, shrinking if it must. The frame is wider than `content`'s
                    // 239.304pt column (sized for the subtitle and button, not this headline) —
                    // without the extra width "CORALIZE" wraps after the "z". A fixed `.frame`
                    // rather than the `.fixedSize()` this used to be: `.fixedSize()` asks for the
                    // text's ideal width and takes it whatever that is, so at the top of the
                    // Dynamic Type range the headline simply ran off both edges of the phone.
                    // A frame gives `minimumScaleFactor` a box to fit into instead.
                    .fitsOneLine(minimumScale: 0.4)
                    .frame(width: headlineWidth)
                Text("Welcome, scientists!\nGet your cards ready.")
                    .font(DesignTokens.Typography.monoBody)
                    .fitsBlock()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
            }
            Button(action: action) {
                Text("Scan a Card")
                    .font(DesignTokens.Typography.button)
                    .foregroundStyle(DesignTokens.whiteText)
                    .fitsOneLine(minimumScale: 0.7)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.secondaryBlue))
                    .overlay(Capsule().stroke(DesignTokens.buttonBorder, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
        }
    }
}

#Preview {
    HomeView()
}
