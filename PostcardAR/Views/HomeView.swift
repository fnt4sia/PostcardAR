//
//  HomeView.swift
//  PostcardAR
//
//  Reproduces the Figma "Home" screen (node 253:1487) — the start screen shown before the
//  camera opens. Wired into ContentView's idle state; `action` starts the scan. All positions
//  below are the frame-relative coordinates Figma reports for this node, kept 1:1 as points.
//
//  The card outline and the two corner grids are drawn from the exact SVGs Figma exports for
//  those nodes (bundled in Assets.xcassets as HomeCardShape/HomeGridTop/HomeGridBottom),
//  rather than reconstructed as native shapes — the card is a boolean subtract with a corner
//  notch that overhangs its own bounding box, and the grids are dashed, gradient-faded lines.
//  Both are exactly the kind of thing that's cheaper and more faithful to trace from the real
//  asset than to re-derive from raw coordinates. See docs/figma-design-to-code's rule on
//  reproducing icons/images from their exported asset rather than hand-authoring them.
//
//  Colors/fonts are DesignTokens.swift — shared with InstructionsPopup.
//

import SwiftUI

/// The start screen: navy background, two faint corner grids, a notched card holding the
/// title, subtitle, and "Scan a Card" button.
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
                Text("SCI.\nMULATE")
                    .font(.custom("JetBrainsMono-Bold", size: 52.788))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
                Text("Welcome, scientists!\nGet your cards ready.")
                    .font(.custom("JetBrainsMono-Regular", size: 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.blackText)
            }
            Button("Scan a Card", action: action)
                .font(.custom("InterVariable", size: 18))
                .foregroundStyle(DesignTokens.whiteText)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(Capsule().fill(DesignTokens.secondaryBlue))
                .overlay(Capsule().stroke(DesignTokens.buttonBorder, lineWidth: 1))
                .buttonStyle(PressableButtonStyle())
        }
    }
}

#Preview {
    HomeView()
}
