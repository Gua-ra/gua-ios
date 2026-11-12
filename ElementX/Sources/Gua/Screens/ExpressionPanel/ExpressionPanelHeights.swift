//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics

/// The panel opens at 60% of the screen, or at the keyboard's last height when that is taller, and expands to 85%.
struct ExpressionPanelHeights: Equatable {
    static let openingFraction: CGFloat = 0.6
    static let expandedFraction: CGFloat = 0.85
    static let closingDistance: CGFloat = 40
    
    /// Heights above the bottom safe area, which the panel's background extends into.
    let opening: CGFloat
    let expanded: CGFloat
    
    init(screenHeight: CGFloat, keyboardHeight: CGFloat?, bottomInset: CGFloat) {
        opening = max(screenHeight * Self.openingFraction, keyboardHeight ?? 0) - bottomInset
        expanded = max(screenHeight * Self.expandedFraction - bottomInset, opening)
    }
    
    func presentation(afterDraggingTo height: CGFloat) -> ExpressionPanelPresentation {
        if height < opening - Self.closingDistance {
            .hidden
        } else if height > (opening + expanded) / 2 {
            .expanded
        } else {
            .compact
        }
    }
}
