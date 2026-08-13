//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

class PlaceholderScreenCoordinator: CoordinatorProtocol {
    private let hideBrandChrome: Bool
    
    init(hideBrandChrome: Bool = true) {
        self.hideBrandChrome = hideBrandChrome
    }
    
    func toPresentable() -> AnyView {
        AnyView(PlaceholderScreen(hideBrandChrome: hideBrandChrome))
    }
}

/// The screen shown in split view when the detail has no content.
struct PlaceholderScreen: View {
    let hideBrandChrome: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if !hideBrandChrome {
                    PrivacyScreenBloom()
                }
            }
            .background()
            .backgroundStyle(.compound.bgCanvasDefault)
            .ignoresSafeArea(edges: .top) // Remain vertically centred even if there's a navigation bar.
            .ignoresSafeArea(.keyboard) // Specifically for the lock screen, but make sense everywhere.
    }

    @ViewBuilder
    private var content: some View {
        if hideBrandChrome {
            // GUA FORK: the empty iPad detail pane. AuthenticationStartLogo is resizable +
            // scaledToFit with no intrinsic cap, so without a frame it scales up to fill the
            // whole detail pane (the "giant logo" bug). Cap it and pair it with a subtle hint
            // so this reads as a tasteful empty state rather than a hero logo.
            VStack(spacing: 16) {
                AuthenticationStartLogo(isOnGradient: false)
                    .frame(maxWidth: 96, maxHeight: 96)

                Text(L10n.screenRoomlistEmptyMessage)
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        } else {
            // GUA FORK: the privacy screen - what the app switcher snapshots, what covers the app
            // as it resigns active, and what sits behind the unlock prompt. It used to draw the
            // app-icon artwork with no size cap on the old launch gradient, so a raw, blown-up
            // icon filled the screen. Show a properly sized mark on the canvas the launch, splash
            // and PIN screens already use, so a locked Gua looks like the rest of Gua.
            PrivacyScreenLogo(size: 96)
        }
    }
}

/// GUA FORK: the app mark on the privacy screen: the icon artwork presented as a tile rather than
/// stretched to fill the screen.
///
/// Deliberately static, and deliberately not `GuaWelcomeLogo`. That one reveals itself from
/// `onAppear` (it has an entrance to play), and this view is what iOS snapshots for the app
/// switcher, so it has to be completely drawn on its very first frame.
private struct PrivacyScreenLogo: View {
    let size: CGFloat

    /// Matches the proportions of the home screen icon, and of the welcome screen's logo tile.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
    }

    var body: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                shape
                    .inset(by: 0.25)
                    .stroke(.white.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: size * 0.16, y: size * 0.07)
            .accessibilityHidden(true)
    }
}

/// GUA FORK: the soft halo behind the privacy screen's mark. Reuses the Compound "subtle" green
/// ramp that paints the home screen bloom, which keeps the locked app unmistakably Gua without
/// the off-brand teal launch gradient that the welcome screen has already moved away from.
private struct PrivacyScreenBloom: View {
    var body: some View {
        RadialGradient(gradient: .compound.subtle,
                       center: .center,
                       startRadius: 0,
                       endRadius: 280)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct PlaceholderScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        PlaceholderScreen(hideBrandChrome: true)
            .previewDisplayName("Screen")
        
        PlaceholderScreen(hideBrandChrome: false)
            .previewDisplayName("With background")

        PlaceholderScreen(hideBrandChrome: false)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("With background dark")

        NavigationSplitView {
            List {
                ForEach("Nothing to see here".split(separator: " "), id: \.self) { word in
                    Text(word)
                }
            }
        } detail: {
            PlaceholderScreen(hideBrandChrome: true)
        }
        .previewDisplayName("Split View")
        .previewInterfaceOrientation(.landscapeLeft)
    }
}
