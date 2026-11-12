//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

/// Marks a still first frame as a GIF when Auto-Play Animated Images is off.
struct AnimatedImageBadge: View {
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    
    var body: some View {
        if !playAnimatedImages {
            Text(L10n.commonGif)
                .font(.compound.bodyXSSemibold)
                .foregroundStyle(.compound.textOnSolidPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(8)
                .accessibilityHidden(true)
        }
    }
}
