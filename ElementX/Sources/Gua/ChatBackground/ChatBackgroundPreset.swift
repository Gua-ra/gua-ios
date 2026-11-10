//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

nonisolated enum ChatBackgroundPreset: String, CaseIterable, Identifiable {
    case aurora
    case mint
    case sky
    case sand
    case blush
    case lavender
    case graphite
    case sunset
    case ocean
    case night
    case dawn
    case forest
    case dusk
    case citrus
    
    static let colours: [ChatBackgroundPreset] = [.mint, .sky, .sand, .blush, .lavender, .graphite]
    static let gradients: [ChatBackgroundPreset] = [.aurora, .sunset, .ocean, .night, .dawn, .forest, .dusk, .citrus]
    
    var id: String {
        rawValue
    }
    
    var name: String {
        switch self {
        case .aurora: UntranslatedL10n.guaChatThemePresetAurora
        case .mint: UntranslatedL10n.guaChatThemePresetMint
        case .sky: UntranslatedL10n.guaChatThemePresetSky
        case .sand: UntranslatedL10n.guaChatThemePresetSand
        case .blush: UntranslatedL10n.guaChatThemePresetBlush
        case .lavender: UntranslatedL10n.guaChatThemePresetLavender
        case .graphite: UntranslatedL10n.guaChatThemePresetGraphite
        case .sunset: UntranslatedL10n.guaChatThemePresetSunset
        case .ocean: UntranslatedL10n.guaChatThemePresetOcean
        case .night: UntranslatedL10n.guaChatThemePresetNight
        case .dawn: UntranslatedL10n.guaChatThemePresetDawn
        case .forest: UntranslatedL10n.guaChatThemePresetForest
        case .dusk: UntranslatedL10n.guaChatThemePresetDusk
        case .citrus: UntranslatedL10n.guaChatThemePresetCitrus
        }
    }
    
    func fill(for colorScheme: ColorScheme) -> ChatBackgroundFill {
        colorScheme == .dark ? dark : light
    }
    
    private var light: ChatBackgroundFill {
        switch self {
        case .aurora: .aurora(base: 0xB2D8C2, glowA: 0x8FCDAB, glowB: 0x93CBCF)
        case .mint: .solid(0xADD7BF)
        case .sky: .solid(0xB6D1EB)
        case .sand: .solid(0xDCC9A9)
        case .blush: .solid(0xE8C3CA)
        case .lavender: .solid(0xD0C6EB)
        case .graphite: .solid(0xC5CAD3)
        case .sunset: .vertical([.init(0xF0C6A6, 0), .init(0xEAB5C2, 0.5), .init(0xCBB5E4, 1)])
        case .ocean: .diagonal([.init(0xA4D5D9, 0), .init(0xA7C6EB, 1)])
        case .night: .vertical([.init(0xC1C6EC, 0), .init(0xD4C0E6, 1)])
        case .dawn: .vertical([.init(0xF6D9BF, 0), .init(0xC9DDF0, 1)])
        case .forest: .diagonal([.init(0xB9D8B0, 0), .init(0x9CC7B4, 1)])
        case .dusk: .vertical([.init(0xD9C2EA, 0), .init(0xF1C9B8, 1)])
        case .citrus: .diagonal([.init(0xF2E6A8, 0), .init(0xBFE3B4, 1)])
        }
    }
    
    private var dark: ChatBackgroundFill {
        switch self {
        case .aurora: .aurora(base: 0x030D08, glowA: 0x061B11, glowB: 0x05181A)
        case .mint: .solid(0x08190F)
        case .sky: .solid(0x0A1524)
        case .sand: .solid(0x19130B)
        case .blush: .solid(0x200F17)
        case .lavender: .solid(0x151125)
        case .graphite: .solid(0x000000)
        case .sunset: .vertical([.init(0x22100C, 0), .init(0x220D1C, 0.5), .init(0x161029, 1)])
        case .ocean: .diagonal([.init(0x05181A, 0), .init(0x09132A, 1)])
        case .night: .vertical([.init(0x0A0D20, 0), .init(0x170C22, 1)])
        case .dawn: .vertical([.init(0x1E140C, 0), .init(0x0B1626, 1)])
        case .forest: .diagonal([.init(0x07140A, 0), .init(0x0A1A14, 1)])
        case .dusk: .vertical([.init(0x140C22, 0), .init(0x21120C, 1)])
        case .citrus: .diagonal([.init(0x1A1606, 0), .init(0x0B1A0C, 1)])
        }
    }
}

/// Points are in unit coordinates of the frame, never mirrored for right-to-left layouts.
nonisolated enum ChatBackgroundFill {
    struct Stop {
        let color: UInt32
        let location: CGFloat
        
        init(_ color: UInt32, _ location: CGFloat) {
            self.color = color
            self.location = location
        }
    }
    
    struct Glow {
        let color: UInt32
        let center: UnitPoint
        /// A fraction of the frame's longest side.
        let radius: CGFloat
    }
    
    case solid(UInt32)
    case linear(start: UnitPoint, end: UnitPoint, stops: [Stop])
    case radialGlows(base: UInt32, glows: [Glow])
    
    static func vertical(_ stops: [Stop]) -> Self {
        .linear(start: UnitPoint(x: 0.5, y: 0), end: UnitPoint(x: 0.5, y: 1), stops: stops)
    }
    
    static func diagonal(_ stops: [Stop]) -> Self {
        .linear(start: UnitPoint(x: 0, y: 0), end: UnitPoint(x: 1, y: 1), stops: stops)
    }
    
    static func aurora(base: UInt32, glowA: UInt32, glowB: UInt32) -> Self {
        .radialGlows(base: base, glows: [Glow(color: glowA, center: UnitPoint(x: 0.30, y: 0.25), radius: 0.75),
                                         Glow(color: glowB, center: UnitPoint(x: 0.75, y: 0.80), radius: 0.65)])
    }
}

extension Color {
    init(chatBackgroundHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension UIColor {
    convenience init(chatBackgroundHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
