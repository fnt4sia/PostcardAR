//
//  DesignTokens.swift
//  PostcardAR
//

import SwiftUI
import CoreText

enum DesignTokens {
    static let whiteText = Color("WhiteText")
    static let blackText = Color("BlackText")
    static let secondaryBlue = Color("SecondaryBlue")
    static let primaryBlue = Color("PrimaryBlue")
    static let buttonBorder = Color(hex: 0xB7FBFF)
    static let progressGradient = LinearGradient(
        colors: [buttonBorder, Color(hex: 0x00288D)],
        startPoint: .top, endPoint: .bottom
    )

    static let fontsRegistered: Bool = {
        let names = ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "Inter-Variable"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
