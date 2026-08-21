//
//  HomeView.swift
//  PostcardAR
//

import SwiftUI

struct HomeView: View {
    var action: () -> Void = {}

    private let background = Color(hex: 0x081A49)

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

                Image("HomeCardShape")
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
                Text("SCI.\nMULATE")
                    .font(.custom("JetBrainsMono-Bold", size: 52.788))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
                Text("Welcome, scientists!\nGet your cards ready.")
                    .font(.custom("JetBrainsMono-Regular", size: 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
            }
            Button(action: action) {
                Text("Scan a Card")
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
}

#Preview {
    HomeView()
}
