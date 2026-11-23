//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

struct ExpressionPanelHeightsTests {
    @Test
    func opensAtSixtyPercentUnlessTheKeyboardWasTaller() {
        #expect(ExpressionPanelHeights(screenHeight: 800, keyboardHeight: 336, bottomInset: 34).opening == 446)
        #expect(ExpressionPanelHeights(screenHeight: 800, keyboardHeight: nil, bottomInset: 0).opening == 480)
        #expect(ExpressionPanelHeights(screenHeight: 600, keyboardHeight: 400, bottomInset: 0).opening == 400)
        #expect(ExpressionPanelHeights(screenHeight: 800, keyboardHeight: nil, bottomInset: 34).expanded == 646)
    }
    
    @Test
    func dragsSettleOnTheNearestHeightOrClose() {
        let heights = ExpressionPanelHeights(screenHeight: 800, keyboardHeight: nil, bottomInset: 0)
        
        #expect(heights.presentation(afterDraggingTo: 480) == .compact)
        #expect(heights.presentation(afterDraggingTo: 450) == .compact)
        #expect(heights.presentation(afterDraggingTo: 430) == .hidden)
        #expect(heights.presentation(afterDraggingTo: 600) == .expanded)
        #expect(heights.presentation(afterDraggingTo: 560) == .compact)
    }
}
