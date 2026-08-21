//
//  LoadingView.swift
//  PostcardAR
//
//  What "Scan a Card" opens onto while `ModelLibrary` loads. The same screen as `HomeView` —
//  background, corner grids, notched card, all at the same Figma coordinates — with the title
//  replaced by a progress read-out, so the transition reads as the card's contents changing
//  rather than as a different app.
//
//  Only ever seen once per launch: the second scan finds the library ready and goes straight to
//  the camera. See `ModelLibrary`.
//

import SwiftUI

struct LoadingView: View {
    /// Models finished and how many there are, straight off the library. Zero of zero before the
    /// reference images have been read, which is why the count is only drawn once `total` is known.
    var loaded: Int
    var total: Int

    private let background = Color(hex: 0x081A49)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background.ignoresSafeArea()

                Image("HomeGridTop")
                    .resizable()
                    .frame(width: 435.469, height: 435)
                    .scaleEffect(x: -1, y: 1) // matches the layer's authored rotation in Figma
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
                Text("LOADING")
                    .font(.custom("JetBrainsMono-Bold", size: 44))
                    .foregroundStyle(DesignTokens.blackText)
                Text(subtitle)
                    .font(.custom("JetBrainsMono-Regular", size: 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: loaded)
            }

            ProgressView()
                .progressViewStyle(.circular)
                .tint(DesignTokens.secondaryBlue)
        }
    }

    /// The reference images are read before any model is, so `total` is 0 for the first stretch —
    /// counting "0 of 0" there would read as a failure rather than as work in progress.
    private var subtitle: String {
        total > 0 ? "Preparing your cards\n\(loaded) of \(total)" : "Preparing your cards"
    }
}

#Preview {
    LoadingView(loaded: 1, total: 2)
}
