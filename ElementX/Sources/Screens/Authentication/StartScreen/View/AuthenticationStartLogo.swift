//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The app's logo styled to fit on various launch pages.
struct AuthenticationStartLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set to `true` when using on top of `Asset.Images.launchBackground`
    let isOnGradient: Bool
    
    /// Extra padding needed to avoid cropping the shadows.
    private let extra: CGFloat = 32
    /// The shape that the logo is composed on top of.
    private let outerShape = RoundedRectangle(cornerRadius: 44)
    private let outerShapeShadowColor = Color(red: 0.11, green: 0.11, blue: 0.13)
    private var isLight: Bool { colorScheme == .light }
    /// The idle shine + breathing animation, disabled when the user prefers reduced motion.
    private var animated: Bool { !reduceMotion }
    
    var body: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .scaleEffect(0.8)
            .overlay { if animated { shine } }
            .clipShape(outerShape)
            .overlay(alignment: .center) {
                outerShape
                    .inset(by: 0.25)
                    .stroke(.white.opacity(isLight ? 1 : isOnGradient ? 0.9 : 0.25), lineWidth: 0.5)
                    .blendMode(isLight ? .normal : .overlay)
            }
            .padding(extra)
            .background {
                ZStack {
                    if !isLight, isOnGradient {
                        outerShape
                            .inset(by: 1)
                            .padding(extra)
                            .shadow(color: .black.opacity(0.5),
                                    radius: 32.91666,
                                    y: 1.05333)
                    } else {
                        outerShape
                            .inset(by: 1)
                            .padding(extra)
                            .shadow(color: outerShapeShadowColor.opacity(isLight ? 0.23 : 0.08),
                                    radius: 16,
                                    y: 8)
                        
                        outerShape
                            .inset(by: 1)
                            .padding(extra)
                            .shadow(color: outerShapeShadowColor.opacity(0.5),
                                    radius: 16,
                                    y: 8)
                            .blendMode(.overlay)
                    }
                }
                .mask {
                    outerShape
                        .inset(by: -extra / 2)
                        .stroke(lineWidth: extra)
                        .padding(extra)
                }
            }
            .padding(-extra)
            .breathing(animated)
            .accessibilityHidden(true)
    }

    /// A soft diagonal highlight that periodically sweeps across the logo, giving it a subtle "shiny" feel.
    private var shine: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let bandWidth = width * 0.42
            Rectangle()
                .fill(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .white.opacity(0.6), location: 0.5),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(width: bandWidth)
                .frame(maxHeight: .infinity)
                .rotationEffect(.degrees(20))
                .blendMode(.plusLighter)
                .phaseAnimator([false, true]) { band, sweeping in
                    band.offset(x: sweeping ? width + bandWidth : -bandWidth)
                } animation: { sweeping in
                    sweeping ? .easeInOut(duration: 1.1) : .linear(duration: 0).delay(3.4)
                }
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// A gentle breathing scale that subtly brings the logo to life while idle.
    @ViewBuilder
    func breathing(_ enabled: Bool) -> some View {
        if enabled {
            phaseAnimator([false, true]) { content, breathing in
                content.scaleEffect(breathing ? 1.028 : 1.0)
            } animation: { _ in
                .easeInOut(duration: 2.8)
            }
        } else {
            self
        }
    }
}
