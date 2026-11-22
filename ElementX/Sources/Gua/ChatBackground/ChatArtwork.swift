//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The built-in wallpapers in gallery order, which must match `Wallpapers/manifest.json`. Raw values go on the wire and never change.
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
    case photoLencoisLagoon = "photo-lencois-lagoon"
    case photoLencoisDunes = "photo-lencois-dunes"
    case photoGrutaAzul = "photo-gruta-azul"
    case photoIpe = "photo-ipe"
    case photoAraucaria = "photo-araucaria"
    case photoManedWolf = "photo-maned-wolf"
    case photoManedWolfStanding = "photo-maned-wolf-standing"
    case photoYukonTrail = "photo-yukon-trail"
    case photoYukonSun = "photo-yukon-sun"
    case photoYukonForest = "photo-yukon-forest"
    case photoYukonSled = "photo-yukon-sled"
    case photoYukonSled2 = "photo-yukon-sled-2"
    case photoPeytoLake = "photo-peyto-lake"
    case photoLoneCanoe = "photo-lone-canoe"
    case photoJasperAurora = "photo-jasper-aurora"
    case photoNunavikAurora = "photo-nunavik-aurora"
    case photoLacDelage = "photo-lac-delage"
    case photoQuebecIce = "photo-quebec-ice"
    case photoQuebecLeaves = "photo-quebec-leaves"
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
        case photos
        case patterns
        case minimal
    }
    
    /// Shown wherever the photo appears: Brazilian copyright law requires the author's name even under CC0.
    struct Credit: Hashable {
        let author: String
        let licence: Licence
        let sourceURL: URL?
    }
    
    /// Raw values are displayed untranslated.
    enum Licence: String {
        case cc0 = "CC0 1.0"
        case ccBy4 = "CC BY 4.0"
        
        var name: String {
            rawValue
        }
        
        var deedURL: URL {
            switch self {
            case .cc0: "https://creativecommons.org/publicdomain/zero/1.0/"
            case .ccBy4: "https://creativecommons.org/licenses/by/4.0/"
            }
        }
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
        case .duneLagoons, .palmCoast, .riverBends, .highlandMist, .glacierLake, .canolaSky, .harbourFog, .canyonGlow, .polarIce, .moonTide: .nature
        case .photoLencoisLagoon, .photoLencoisDunes, .photoGrutaAzul, .photoIpe, .photoAraucaria, .photoManedWolf, .photoManedWolfStanding,
             .photoYukonTrail, .photoYukonSun, .photoYukonForest, .photoYukonSled, .photoYukonSled2, .photoPeytoLake, .photoLoneCanoe,
             .photoJasperAurora, .photoNunavikAurora, .photoLacDelage, .photoQuebecIce, .photoQuebecLeaves: .photos
        case .currents, .azulejo, .calcadao, .knit, .doodlesBrasil, .doodlesCanada: .patterns
        case .paper, .paperCut: .minimal
        }
    }
    
    /// Whether the artwork moves.
    var isLive: Bool {
        section == .live
    }
    
    var isPhoto: Bool {
        section == .photos
    }
    
    /// Photos have no dark variant, so dark appearance dims them like a user's own photo.
    var photoDim: Double? {
        isPhoto ? ChatBackground.Photo.defaultDim : nil
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
        case .photoLencoisLagoon: UntranslatedL10n.guaChatThemeArtPhotoLencoisLagoon
        case .photoLencoisDunes: UntranslatedL10n.guaChatThemeArtPhotoLencoisDunes
        case .photoGrutaAzul: UntranslatedL10n.guaChatThemeArtPhotoGrutaAzul
        case .photoIpe: UntranslatedL10n.guaChatThemeArtPhotoIpe
        case .photoAraucaria: UntranslatedL10n.guaChatThemeArtPhotoAraucaria
        case .photoManedWolf: UntranslatedL10n.guaChatThemeArtPhotoManedWolf
        case .photoManedWolfStanding: UntranslatedL10n.guaChatThemeArtPhotoManedWolfStanding
        case .photoYukonTrail: UntranslatedL10n.guaChatThemeArtPhotoYukonTrail
        case .photoYukonSun: UntranslatedL10n.guaChatThemeArtPhotoYukonSun
        case .photoYukonForest: UntranslatedL10n.guaChatThemeArtPhotoYukonForest
        case .photoYukonSled: UntranslatedL10n.guaChatThemeArtPhotoYukonSled
        case .photoYukonSled2: UntranslatedL10n.guaChatThemeArtPhotoYukonSled2
        case .photoPeytoLake: UntranslatedL10n.guaChatThemeArtPhotoPeytoLake
        case .photoLoneCanoe: UntranslatedL10n.guaChatThemeArtPhotoLoneCanoe
        case .photoJasperAurora: UntranslatedL10n.guaChatThemeArtPhotoJasperAurora
        case .photoNunavikAurora: UntranslatedL10n.guaChatThemeArtPhotoNunavikAurora
        case .photoLacDelage: UntranslatedL10n.guaChatThemeArtPhotoLacDelage
        case .photoQuebecIce: UntranslatedL10n.guaChatThemeArtPhotoQuebecIce
        case .photoQuebecLeaves: UntranslatedL10n.guaChatThemeArtPhotoQuebecLeaves
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
        case .photoLencoisLagoon: ChatBubblePair(.teal, dark: .purple)
        case .photoLencoisDunes: ChatBubblePair(.blue, dark: .purple)
        case .photoGrutaAzul: ChatBubblePair(.teal, dark: .blue)
        case .photoIpe: ChatBubblePair(.blue, dark: .orange)
        case .photoAraucaria: ChatBubblePair(.green, dark: .teal)
        case .photoManedWolf: ChatBubblePair(.blue, dark: .purple)
        case .photoManedWolfStanding: ChatBubblePair(.blue, dark: .purple)
        case .photoYukonTrail: ChatBubblePair(.blue, dark: .teal)
        case .photoYukonSun: ChatBubblePair(.orange, dark: .blue)
        case .photoYukonForest: ChatBubblePair(.green, dark: .teal)
        case .photoYukonSled: ChatBubblePair(.purple, dark: .blue)
        case .photoYukonSled2: ChatBubblePair(.teal, dark: .purple)
        case .photoPeytoLake: ChatBubblePair(.teal, dark: .blue)
        case .photoLoneCanoe: ChatBubblePair(.orange, dark: .purple)
        case .photoJasperAurora: ChatBubblePair(.green, dark: .teal)
        case .photoNunavikAurora: ChatBubblePair(.purple, dark: .pink)
        case .photoLacDelage: ChatBubblePair(.blue)
        case .photoQuebecIce: ChatBubblePair(.green, dark: .teal)
        case .photoQuebecLeaves: ChatBubblePair(.teal, dark: .graphite)
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
        case .photoLencoisLagoon: UnitPoint(x: 0.5, y: 0.52)
        case .photoLencoisDunes: UnitPoint(x: 0.35, y: 0.46)
        case .photoGrutaAzul: UnitPoint(x: 0.65, y: 0.68)
        case .photoIpe: UnitPoint(x: 0.47, y: 0.28)
        case .photoAraucaria: UnitPoint(x: 0.45, y: 0.42)
        case .photoManedWolf: UnitPoint(x: 0.38, y: 0.55)
        case .photoManedWolfStanding: UnitPoint(x: 0.72, y: 0.25)
        case .photoYukonTrail: UnitPoint(x: 0.45, y: 0.55)
        case .photoYukonSun: UnitPoint(x: 0.5, y: 0.72)
        case .photoYukonForest: UnitPoint(x: 0.53, y: 0.68)
        case .photoYukonSled: UnitPoint(x: 0.5, y: 0.62)
        case .photoYukonSled2: UnitPoint(x: 0.5, y: 0.7)
        case .photoPeytoLake: UnitPoint(x: 0.4, y: 0.6)
        case .photoLoneCanoe: UnitPoint(x: 0.48, y: 0.62)
        case .photoJasperAurora: UnitPoint(x: 0.5, y: 0.55)
        case .photoNunavikAurora: UnitPoint(x: 0.5, y: 0.4)
        case .photoLacDelage: UnitPoint(x: 0.5, y: 0.35)
        case .photoQuebecIce: UnitPoint(x: 0.47, y: 0.7)
        case .photoQuebecLeaves: UnitPoint(x: 0.5, y: 0.5)
        case .paperCut: UnitPoint(x: 1, y: 0)
        case .moltenPearl, .silk, .currentsLive, .riverBends, .currents, .azulejo, .calcadao, .doodlesBrasil, .doodlesCanada, .paper: .center
        }
    }
    
    /// What builds that don't know the artwork show instead: written with it, and never changed once shipped.
    var fallbackPreset: ChatBackgroundPreset {
        switch self {
        case .glassDrops: .blush
        case .glassDropsBlue, .moltenPearl, .azulejo: .sky
        case .silk, .pantanal, .duneLagoons, .riverBends, .highlandMist, .doodlesBrasil: .mint
        case .ipe: .sunset
        case .rainOnGlass: .aurora
        case .currentsLive, .currents: .lavender
        case .palmCoast, .glacierLake, .harbourFog, .moonTide: .ocean
        case .canolaSky, .canyonGlow, .calcadao, .knit, .doodlesCanada, .paper, .paperCut: .sand
        case .polarIce: .night
        case .photoLencoisLagoon, .photoGrutaAzul, .photoAraucaria, .photoYukonTrail, .photoYukonSun, .photoYukonForest, .photoYukonSled, .photoYukonSled2, .photoJasperAurora: .sky
        case .photoLencoisDunes, .photoIpe: .graphite
        case .photoManedWolf, .photoLacDelage, .photoQuebecIce, .photoQuebecLeaves: .sand
        case .photoManedWolfStanding, .photoNunavikAurora: .mint
        case .photoPeytoLake, .photoLoneCanoe: .ocean
        }
    }
    
    var credit: Credit? {
        switch self {
        case .photoLencoisLagoon:
            Credit(author: "Gerda Arendt", licence: .cc0,
                   sourceURL: "https://commons.wikimedia.org/wiki/File:Lagoon_in_curved_sanddunes%2C_Len%C3%A7%C3%B3is_Maranhenses.jpg")
        case .photoLencoisDunes:
            Credit(author: "Gerda Arendt", licence: .cc0,
                   sourceURL: "https://commons.wikimedia.org/wiki/File:Sand_dunes_before_sunset%2C_Len%C3%A7%C3%B3is_Maranhenses.jpg")
        case .photoGrutaAzul:
            Credit(author: "Wilfredo Rodriguez (Wilfredor)", licence: .cc0,
                   sourceURL: "https://commons.wikimedia.org/wiki/File:Rock_walls_and_entrance_of_Gruta_Azul%2C_Arraial_do_Cabo%2C_Brazil.jpg")
        case .photoIpe:
            Credit(author: "Thyrome", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Handroanthus_ochraceus.jpg")
        case .photoAraucaria:
            Credit(author: "Themium", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Arauc%C3%A1ria_jordanense_1.jpg")
        case .photoManedWolf:
            Credit(author: "Wilfredo Rodriguez (Wilfredor)", licence: .cc0,
                   sourceURL: "https://commons.wikimedia.org/wiki/File:Chrysocyon_brachyurus_in_S%C3%A3o_Paulo_Zoo.jpg")
        case .photoManedWolfStanding:
            Credit(author: "Gil Myers, Smithsonian's National Zoo", licence: .cc0, sourceURL: "https://nationalzoo.si.edu/object/nzp_NZP-20160729-011GM")
        case .photoYukonTrail, .photoYukonSun, .photoYukonForest, .photoYukonSled, .photoYukonSled2:
            Credit(author: "Sarah Lacerda", licence: .ccBy4, sourceURL: nil)
        case .photoPeytoLake:
            Credit(author: "Ezra Jeffrey-Comeau", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:The_Highest_Highs_(Unsplash).jpg")
        case .photoLoneCanoe:
            Credit(author: "Braxton Stuntz", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:The_Lone_Canoe_(Unsplash).jpg")
        case .photoJasperAurora:
            Credit(author: "Priscilla Du Preez", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Northern_lights_over_a_lake_(Unsplash).jpg")
        case .photoNunavikAurora:
            Credit(author: "Nicolas M. Perrault", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Aurora_Borealis_in_Kangiqsualujjaq.tif")
        case .photoLacDelage:
            Credit(author: "Wilfredo Rodriguez (Wilfredor)", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Lac_Delage_at_night,_Quebec,_Canada.jpg")
        case .photoQuebecIce:
            Credit(author: "Wilfredo Rodriguez (Wilfredor)", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Ice_on_a_branch_in_Quebec_City.jpg")
        case .photoQuebecLeaves:
            Credit(author: "Wilfredo Rodriguez (Wilfredor)", licence: .cc0, sourceURL: "https://commons.wikimedia.org/wiki/File:Autumn_leaves_on_the_ground_in_Quebec_City.jpg")
        case .glassDrops, .glassDropsBlue, .moltenPearl, .silk, .ipe, .rainOnGlass, .pantanal, .currentsLive,
             .duneLagoons, .palmCoast, .riverBends, .highlandMist, .glacierLake, .canolaSky, .harbourFog, .canyonGlow, .polarIce, .moonTide,
             .currents, .azulejo, .calcadao, .knit, .doodlesBrasil, .doodlesCanada, .paper, .paperCut:
            nil
        }
    }
    
    var fileNames: (light: String, dark: String) {
        isPhoto ? ("\(rawValue).webp", "\(rawValue).webp") : ("\(rawValue)-light.webp", "\(rawValue)-dark.webp")
    }
    
    func fileName(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? fileNames.dark : fileNames.light
    }
}
