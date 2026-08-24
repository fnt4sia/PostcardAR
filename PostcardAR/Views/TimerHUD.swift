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
                        .font(.custom("JetBrainsMono-Regular", size: 34))
                        .foregroundStyle(DesignTokens.whiteText)
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
                    .font(.custom("InterVariable", size: 13.71))
                    .foregroundStyle(DesignTokens.blackText)
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
