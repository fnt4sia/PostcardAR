//
//  DesignTokens.swift
//  PostcardAR
//

import SwiftUI
import CoreText

enum DesignTokens {
    static let whiteText = Color("WhiteText")
    static let blackText = Color("BlackText")
    static let blueText = Color("BlueText")
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

// MARK: - Typography

/// Every piece of type in the app, named by the job it does.
///
/// The sizes are the Figma ones and are unchanged; what each token adds is **which Dynamic Type
/// curve it grows along**, and that is the whole point of collecting them here.
///
/// `Font.custom(_:size:)` — which is what every screen used to call directly — is not a fixed size.
/// It scales, and it scales relative to **`.body`**, whatever the size handed to it. That is right
/// for an 18 pt paragraph and wrong for a 164 pt numeral: body grows by about 130% at the largest
/// accessibility setting, so the countdown digit was heading for 380 pt inside a 282 pt card, and
/// the result score for 166 pt. Pinning each token to the text style it actually resembles —
/// display type to `.largeTitle`, captions to `.caption` — puts every size on the curve Apple tuned
/// for type of that weight, and the big ones then grow by a sensible fraction instead of by the
/// fraction meant for body copy.
///
/// Three things work together and all three are needed; drop one and the layouts break at the top
/// of the range:
///
/// 1. **These tokens**, so each size grows on its own curve.
/// 2. **`accessibleLayout()`**, applied once at the root, capping the range the screens are
///    designed to absorb.
/// 3. **`lineLimit` and `minimumScaleFactor`** at each site where the geometry around the text is
///    fixed — the traced cards, the HUD capsule, the hint bar. The cap keeps text inside the
///    layouts in the ordinary case; shrink-to-fit is what guarantees it, and is why nothing can
///    clip however the tokens are later retuned.
///
/// See `docs/app-shell.md`.
extension DesignTokens {
    enum Typography {
        private static let mono = "JetBrainsMono-Regular"
        private static let monoBold = "JetBrainsMono-Bold"
        private static let sans = "InterVariable"

        // Display — the one-word headlines a screen is named by.
        static let homeTitle = Font.custom(monoBold, size: 52.788, relativeTo: .largeTitle)
        static let loadingTitle = Font.custom(monoBold, size: 44, relativeTo: .largeTitle)

        // Panel titles — the line at the top of a traced card.
        static let panelTitle = Font.custom(monoBold, size: 34, relativeTo: .title)
        static let resultTitle = Font.custom(monoBold, size: 28, relativeTo: .title2)

        // Numerals. `.largeTitle` rather than `.body`: these are already large, and only need to
        // grow enough to stay legible, not enough to burst the card holding them.
        static let resultValue = Font.custom(monoBold, size: 72, relativeTo: .largeTitle)
        static let graceValue = Font.custom(monoBold, size: 60, relativeTo: .largeTitle)
        static let clock = Font.custom(mono, size: 34, relativeTo: .title)

        /// The countdown digit and its "START!", which differ in size — see `CountdownCard`.
        static func countdownValue(size: CGFloat) -> Font {
            .custom(monoBold, size: size, relativeTo: .largeTitle)
        }

        // Reading text.
        static let body = Font.custom(sans, size: 18, relativeTo: .body)
        static let monoBody = Font.custom(mono, size: 18, relativeTo: .body)
        static let button = Font.custom(sans, size: 18, relativeTo: .body)
        static let hint = Font.custom(mono, size: 20, relativeTo: .callout)
        static let resultLabel = Font.custom(mono, size: 18, relativeTo: .subheadline)

        /// The `3/8` inside the progress track. Raised from Figma's 13.71 to 14 — the track is
        /// 23 pt tall and this is the smallest type in the app, so it is the one number worth
        /// nudging up rather than leaving traced exactly.
        static let scoreFraction = Font.custom(sans, size: 14, relativeTo: .caption)
    }

    /// Largest text setting the traced layouts are built to absorb.
    ///
    /// The screens are fixed-size cards at Figma coordinates — 344 × 439 with a 266 pt content
    /// column — so text cannot grow indefinitely without leaving them.
    ///
    /// **`.xxxLarge` is measured, not guessed.** At `.accessibility1` the instructions card puts its
    /// title above the card's top edge and its Start button below the bottom one — the content is
    /// simply taller than 439 pt by then, and no amount of shrinking inside the column fixes a
    /// column that has run out of card. `.xxxLarge` is the last step every panel still holds, and it
    /// is about a quarter larger than the default. Anything above is clamped down to it, so a device
    /// set to AX5 gets `.xxxLarge` here — bigger than default, and still inside the design — rather
    /// than an overlapping mess.
    ///
    /// Raising this means giving the cards room first: the artwork is a fixed-size image, so the
    /// honest way past `.xxxLarge` is a card that grows with its content, not a larger cap.
    static let maximumDynamicTypeSize = DynamicTypeSize.xxxLarge
}

extension View {
    /// Caps Dynamic Type at what the traced layouts can hold — see
    /// `DesignTokens.maximumDynamicTypeSize`.
    ///
    /// Applied **once**, at the root in `ContentView`, so every screen and every AR overlay inherits
    /// it through the environment. Do not scatter it per screen: the cap is a property of the design,
    /// not of any one panel, and a second call somewhere else is how the two drift apart.
    func accessibleLayout() -> some View {
        dynamicTypeSize(...DesignTokens.maximumDynamicTypeSize)
    }

    /// Lets one line of text shrink rather than wrap or clip, for text in fixed geometry.
    ///
    /// The counterpart to the cap: where a card, a capsule or a bar is a fixed number of points
    /// wide, the text inside it has to be allowed to give. Shrinking is the graceful failure —
    /// slightly smaller and fully readable beats correctly sized and cut in half.
    func fitsOneLine(minimumScale: CGFloat = 0.5) -> some View {
        lineLimit(1).minimumScaleFactor(minimumScale)
    }

    /// Lets wrapping text shrink to fit the room left for it, rather than being truncated.
    ///
    /// SwiftUI's fallback when a fixed-height card cannot fit its column is to *truncate* the most
    /// compressible text in it, and on these panels that is the title — "POINT AT THE CARD AGAIN"
    /// came out as "POINT AT THE CARD…" before this was added. Shrinking a title by a fifth is
    /// invisible; losing its last word is not.
    func fitsBlock(minimumScale: CGFloat = 0.6) -> some View {
        minimumScaleFactor(minimumScale)
    }
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

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
