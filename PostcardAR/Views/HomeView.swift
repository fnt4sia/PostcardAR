//
//  HomeView.swift
//  PostcardAR
//


import SwiftUI
struct HomeView: View {
    private let fontsRegistered = HomeTokens.fontsRegistered

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                HomeTokens.background.ignoresSafeArea()

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
                    .foregroundStyle(HomeTokens.blackText)
                Text("Welcome, scientists!\nGet your cards ready.")
                    .font(.custom("JetBrainsMono-Regular", size: 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(HomeTokens.blackText)
            }
            Button("Scan a Card") {}
                .font(.system(size: 18))
                .foregroundStyle(HomeTokens.whiteText)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(Capsule().fill(HomeTokens.secondaryBlue))
                .overlay(Capsule().stroke(HomeTokens.buttonBorder, lineWidth: 1))
        }
    }
}

private enum HomeTokens {
    static let background = Color(hex: 0x081A49)
    static let buttonBorder = Color(hex: 0xB7FBFF)
    static let blackText = Color("BlackText")
    static let whiteText = Color("WhiteText")
    static let secondaryBlue = Color("SecondaryBlue")

    static let fontsRegistered: Bool = {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    HomeView()
}
