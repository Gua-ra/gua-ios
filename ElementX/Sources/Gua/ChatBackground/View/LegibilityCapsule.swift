//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

extension EnvironmentValues {
    @Entry var chatBackgroundActive = false
}

enum LegibilityCapsuleShape {
    /// Fully rounded while it holds a single line, so a notice that wraps keeps its corners clear of the text.
    case capsule
    case circle
    case roundedRectangle(cornerRadius: CGFloat)
}

private struct LegibilityCapsuleModifier: ViewModifier {
    let shape: LegibilityCapsuleShape
    let hasPadding: Bool
    let isEnabled: Bool

    @Environment(\.chatBackgroundActive) private var isActive
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ScaledMetric private var horizontalPadding = 8.0
    @ScaledMetric private var verticalPadding = 3.0

    func body(content: Content) -> some View {
        if isActive, isEnabled {
            content
                .padding(.horizontal, padding.horizontal)
                .padding(.vertical, padding.vertical)
                .background { fill }
        } else {
            content
        }
    }

    private var padding: (horizontal: CGFloat, vertical: CGFloat) {
        switch (hasPadding, shape) {
        case (false, _):
            (0, 0)
        case (true, .circle):
            (verticalPadding * 2, verticalPadding * 2)
        case (true, _):
            (horizontalPadding, verticalPadding)
        }
    }

    private var fill: some View {
        let color = Color.compound.bgCanvasDefault.opacity(isOpaque ? 1 : 0.88)
        return GeometryReader { geometry in
            switch shape {
            case .capsule:
                RoundedRectangle(cornerRadius: min(geometry.size.height / 2, 12)).fill(color)
            case .circle:
                Circle().fill(color)
            case .roundedRectangle(let cornerRadius):
                RoundedRectangle(cornerRadius: cornerRadius).fill(color)
            }
        }
    }

    private var isOpaque: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }
}

private struct LegibleSecondaryForegroundModifier: ViewModifier {
    @Environment(\.chatBackgroundActive) private var isActive

    func body(content: Content) -> some View {
        content.foregroundColor(isActive ? .compound.textPrimary : .compound.textSecondary)
    }
}

extension View {
    func legibilityCapsule(_ shape: LegibilityCapsuleShape = .capsule, hasPadding: Bool = true, isEnabled: Bool = true) -> some View {
        modifier(LegibilityCapsuleModifier(shape: shape, hasPadding: hasPadding, isEnabled: isEnabled))
    }

    func legibleSecondaryForeground() -> some View {
        modifier(LegibleSecondaryForegroundModifier())
    }
}

extension Color {
    /// The ring cuts a pill or avatar out of the bubble, and over a background it would show as a halo.
    static func cutOutRing(isOnBackground: Bool) -> Color {
        isOnBackground ? .clear : .compound.bgCanvasDefault
    }
}

struct LegibilityCapsule_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        capsules
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Translucent")

        capsules
            .environment(\._accessibilityReduceTransparency, true)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Reduce Transparency")

        capsules
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .environment(\._colorSchemeContrast, .increased)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Increase Contrast dark")
    }

    static var capsules: some View {
        VStack(spacing: 12) {
            Text("Tuesday 3 November 2026")
                .font(.compound.bodySMSemibold)
                .foregroundColor(.compound.textPrimary)
                .legibilityCapsule()

            Text(UntranslatedL10n.guaChatThemeNoticeChanged("Helena Martins, who has a long name that wraps"))
                .font(.compound.bodySM)
                .multilineTextAlignment(.center)
                .legibleSecondaryForeground()
                .legibilityCapsule()
                .frame(width: 240)

            CompoundIcon(\.reply)
                .foregroundColor(.compound.iconPrimary)
                .legibilityCapsule(.circle)

            ProgressView()
                .legibilityCapsule()
        }
        .environment(\.chatBackgroundActive, true)
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Color(chatBackgroundHex: 0x1F9D5B), Color(chatBackgroundHex: 0xF0C6A6)], startPoint: .top, endPoint: .bottom)
        }
    }
}
