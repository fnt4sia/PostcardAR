//
//  TimerHUD.swift
//  PostcardAR
//

import SwiftUI

struct TimerHUD: View {
    var secondsRemaining: Int
    var current: Int
    var total: Int

    private let trackWidth: CGFloat = 244
    private let trackHeight: CGFloat = 23

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(DesignTokens.primaryBlue)
                .frame(width: 200, height: 50)
                .overlay {
                    Text(timeString)
                        .font(DesignTokens.Typography.clock)
                        .foregroundStyle(DesignTokens.whiteText)
                        // The capsule behind it is a fixed 200 x 50.
                        .fitsOneLine(minimumScale: 0.6)
                        .padding(.horizontal, 12)
                }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.whiteText)
                    .frame(width: trackWidth, height: trackHeight)

                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignTokens.progressGradient)
                    .frame(width: fillWidth, height: trackHeight)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)

                Text("\(current)/\(total)")
                    .font(DesignTokens.Typography.scoreFraction)
                    .foregroundStyle(DesignTokens.blackText)
                    // Inside a 23pt-tall track, so it shrinks rather than pushing the track open.
                    .fitsOneLine(minimumScale: 0.7)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: current)
                    .offset(x: 109)
            }
        }
    }

    private var timeString: String {
        String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60)
    }

    private var fillWidth: CGFloat {
        guard total > 0 else { return 0 }
        return trackWidth * CGFloat(current) / CGFloat(total)
    }
}

#Preview {
    ZStack {
        Color(hex: 000000).ignoresSafeArea()
        TimerHUD(secondsRemaining: 30, current: 3, total: 8)
    }
}
