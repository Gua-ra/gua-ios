//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The illustrated wallpapers in gallery order, which must match `Wallpapers/manifest.json`. Raw values go on the wire and never change.
nonisolated enum ChatArtwork: String, CaseIterable, Identifiable {
    case glassDrops = "glass-drops"
    case glassDropsBlue = "glass-drops-blue"
    case moltenPearl = "molten-pearl"
    case silk
    case ipe
    case rainOnGlass = "rain-on-glass"
    case pantanal
    case currentsLive = "currents-live"
    case duneLagoons = "dune-lagoons"
    case palmCoast = "palm-coast"
    case riverBends = "river-bends"
    case highlandMist = "highland-mist"
    case glacierLake = "glacier-lake"
    case canolaSky = "canola-sky"
    case harbourFog = "harbour-fog"
    case canyonGlow = "canyon-glow"
    case polarIce = "polar-ice"
    case moonTide = "moon-tide"
    case guara
    case currents
    case azulejo
    case calcadao
    case knit
    case doodlesBrasil = "doodles-brasil"
    case doodlesCanada = "doodles-canada"
    case paper
    case paperCut = "paper-cut"
    
    enum Section: String {
        case live
        case nature
        case patterns
        case minimal
    }
    
    /// The bundle folder that holds the images, kept as a folder so they keep this path.
    static let folder = "Wallpapers"
    /// Every image is a full phone screen in portrait, in both appearances.
    static let pixelSize = CGSize(width: 1290, height: 2796)
    
    static func artworks(in section: Section) -> [ChatArtwork] {
        allCases.filter { $0.section == section }
    }
    
    var id: String {
        rawValue
    }
    
    var section: Section {
        switch self {
        case .glassDrops, .glassDropsBlue, .moltenPearl, .silk, .ipe, .rainOnGlass, .pantanal, .currentsLive: .live
        case .duneLagoons, .palmCoast, .riverBends, .highlandMist, .glacierLake, .canolaSky, .harbourFog, .canyonGlow, .polarIce, .moonTide, .guara: .nature
        case .currents, .azulejo, .calcadao, .knit, .doodlesBrasil, .doodlesCanada: .patterns
        case .paper, .paperCut: .minimal
        }
    }
    
    /// Whether the artwork moves.
    var isLive: Bool {
        section == .live
    }
    
    var name: String {
        switch self {
        case .glassDrops: UntranslatedL10n.guaChatThemeArtGlassDrops
        case .glassDropsBlue: UntranslatedL10n.guaChatThemeArtGlassDropsBlue
        case .moltenPearl: UntranslatedL10n.guaChatThemeArtMoltenPearl
        case .silk: UntranslatedL10n.guaChatThemeArtSilk
        case .ipe: UntranslatedL10n.guaChatThemeArtIpe
        case .rainOnGlass: UntranslatedL10n.guaChatThemeArtRainOnGlass
        case .pantanal: UntranslatedL10n.guaChatThemeArtPantanal
        case .currentsLive: UntranslatedL10n.guaChatThemeArtCurrentsLive
        case .duneLagoons: UntranslatedL10n.guaChatThemeArtDuneLagoons
        case .palmCoast: UntranslatedL10n.guaChatThemeArtPalmCoast
        case .riverBends: UntranslatedL10n.guaChatThemeArtRiverBends
        case .highlandMist: UntranslatedL10n.guaChatThemeArtHighlandMist
        case .glacierLake: UntranslatedL10n.guaChatThemeArtGlacierLake
        case .canolaSky: UntranslatedL10n.guaChatThemeArtCanolaSky
        case .harbourFog: UntranslatedL10n.guaChatThemeArtHarbourFog
        case .canyonGlow: UntranslatedL10n.guaChatThemeArtCanyonGlow
        case .polarIce: UntranslatedL10n.guaChatThemeArtPolarIce
        case .moonTide: UntranslatedL10n.guaChatThemeArtMoonTide
        case .guara: UntranslatedL10n.guaChatThemeArtGuara
        case .currents: UntranslatedL10n.guaChatThemeArtCurrents
        case .azulejo: UntranslatedL10n.guaChatThemeArtAzulejo
        case .calcadao: UntranslatedL10n.guaChatThemeArtCalcadao
        case .knit: UntranslatedL10n.guaChatThemeArtKnit
        case .doodlesBrasil: UntranslatedL10n.guaChatThemeArtDoodlesBrasil
        case .doodlesCanada: UntranslatedL10n.guaChatThemeArtDoodlesCanada
        case .paper: UntranslatedL10n.guaChatThemeArtPaper
        case .paperCut: UntranslatedL10n.guaChatThemeArtPaperCut
        }
    }
    
    /// The bubbles the artwork was picked with.
    var bubbles: ChatBubblePair {
        switch self {
        case .glassDrops: ChatBubblePair(.purple, dark: .pink)
        case .glassDropsBlue: ChatBubblePair(.teal)
        case .moltenPearl: ChatBubblePair(.purple, dark: .blue)
        case .silk: ChatBubblePair(.teal)
        case .ipe: ChatBubblePair(.pink, dark: .yellow)
        case .rainOnGlass: ChatBubblePair(.green, dark: .blue)
        case .pantanal: ChatBubblePair(.green)
        case .currentsLive: ChatBubblePair(.purple)
        case .duneLagoons: ChatBubblePair(.teal, dark: .purple)
        case .palmCoast: ChatBubblePair(.orange, dark: .blue)
        case .riverBends: ChatBubblePair(.teal)
        case .highlandMist: ChatBubblePair(.blue, dark: .green)
        case .glacierLake: ChatBubblePair(.teal)
        case .canolaSky: ChatBubblePair(.green, dark: .orange)
        case .harbourFog: ChatBubblePair(.blue)
        case .canyonGlow: ChatBubblePair(.blue, dark: .purple)
        case .polarIce: ChatBubblePair(.blue, dark: .purple)
        case .moonTide: ChatBubblePair(.blue)
        case .guara: ChatBubblePair(.green)
        case .currents: ChatBubblePair(.purple)
        case .azulejo: ChatBubblePair(.blue)
        case .calcadao: ChatBubblePair(.teal)
        case .knit: ChatBubblePair(.blue)
        case .doodlesBrasil: ChatBubblePair(.green)
        case .doodlesCanada: ChatBubblePair(.blue)
        case .paper: ChatBubblePair(.green)
        case .paperCut: ChatBubblePair(.teal, dark: .orange)
        }
    }
    
    /// The point of the image that stays on screen when it is cropped, used as the photo alignment.
    var anchor: UnitPoint {
        switch self {
        case .glassDrops: UnitPoint(x: 0.5, y: 0.08)
        case .glassDropsBlue: UnitPoint(x: 0.5, y: 0.35)
        case .ipe, .knit: UnitPoint(x: 0.5, y: 0)
        case .rainOnGlass, .highlandMist, .canyonGlow, .polarIce: UnitPoint(x: 0.5, y: 0.3)
        case .pantanal: UnitPoint(x: 0.5, y: 0.38)
        case .duneLagoons: UnitPoint(x: 0.5, y: 0.25)
        case .palmCoast: UnitPoint(x: 0.5, y: 0.2)
        case .glacierLake: UnitPoint(x: 0.5, y: 0.35)
        case .canolaSky: UnitPoint(x: 0.4, y: 0.38)
        case .harbourFog: UnitPoint(x: 0.7, y: 0.3)
        case .moonTide: UnitPoint(x: 0.5, y: 0.72)
        case .guara: UnitPoint(x: 0.78, y: 0.19)
        case .paperCut: UnitPoint(x: 1, y: 0)
        case .moltenPearl, .silk, .currentsLive, .riverBends, .currents, .azulejo, .calcadao, .doodlesBrasil, .doodlesCanada, .paper: .center
        }
    }
    
    /// What builds that don't know the artwork show instead: written with it, and never changed once shipped.
    var fallbackPreset: ChatBackgroundPreset {
        switch self {
        case .glassDrops: .blush
        case .glassDropsBlue, .moltenPearl, .azulejo: .sky
        case .silk, .pantanal, .duneLagoons, .riverBends, .highlandMist, .guara, .doodlesBrasil: .mint
        case .ipe: .sunset
        case .rainOnGlass: .aurora
        case .currentsLive, .currents: .lavender
        case .palmCoast, .glacierLake, .harbourFog, .moonTide: .ocean
        case .canolaSky, .canyonGlow, .calcadao, .knit, .doodlesCanada, .paper, .paperCut: .sand
        case .polarIce: .night
        }
    }
    
    var fileNames: (light: String, dark: String) {
        ("\(rawValue)-light.webp", "\(rawValue)-dark.webp")
    }
    
    func fileName(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? fileNames.dark : fileNames.light
    }
}
