//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// In picker order. Android ships the same IDs and colours, all darker than the bubbles of their appearance.
enum ChatBackgroundPreset: String, CaseIterable, Identifiable {
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

    private static let idFormat = /^[a-z0-9_]{1,32}$/

    init?(id: String) {
        guard id.wholeMatch(of: Self.idFormat) != nil else { return nil }
        self.init(rawValue: id)
    }

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .aurora: UntranslatedL10n.guaChatBackgroundPresetAurora
        case .mint: UntranslatedL10n.guaChatBackgroundPresetMint
        case .sky: UntranslatedL10n.guaChatBackgroundPresetSky
        case .sand: UntranslatedL10n.guaChatBackgroundPresetSand
        case .blush: UntranslatedL10n.guaChatBackgroundPresetBlush
        case .lavender: UntranslatedL10n.guaChatBackgroundPresetLavender
        case .graphite: UntranslatedL10n.guaChatBackgroundPresetGraphite
        case .sunset: UntranslatedL10n.guaChatBackgroundPresetSunset
        case .ocean: UntranslatedL10n.guaChatBackgroundPresetOcean
        case .night: UntranslatedL10n.guaChatBackgroundPresetNight
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
        }
    }
}

/// Points are in unit coordinates of the frame, never mirrored for right-to-left layouts.
enum ChatBackgroundFill: Equatable {
    struct Stop: Equatable {
        let color: UInt32
        let location: CGFloat

        init(_ color: UInt32, _ location: CGFloat) {
            self.color = color
            self.location = location
        }
    }

    struct Glow: Equatable {
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
