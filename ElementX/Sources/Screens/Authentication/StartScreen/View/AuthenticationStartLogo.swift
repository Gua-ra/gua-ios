//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The app's logo with an "Apple-Intelligence/Siri"-style living aura: a flowing, multi-hue
/// conic gradient continuously rotates behind the icon and spills out as a soft glow.
///
/// It is disabled when the user prefers reduced motion.
struct AuthenticationStartLogo: View {
    /// Set to specify a custom size for the Logo, otherwise the default size of 158pt will be used.
    var size: CGFloat?
    /// Set to `true` to skip the brand chrome.
    let hideBrandChrome: Bool
    /// Set to `true` when using on top of `Asset.Images.launchBackground`.
    let isOnGradient: Bool
    
    private let appLogoImage = Image(asset: Asset.Images.appLogo)
    
    struct SizeMetrics {
        let scale: CGFloat
        let imageSize: CGFloat
    }
    
    private var sizeMetrics: SizeMetrics? {
        size.map { customSize in
            let scale = customSize / 158
            return SizeMetrics(scale: scale,
                               imageSize: hideBrandChrome ? customSize : 110 * scale)
        }
    }
    
    var body: some View {
        if let sizeMetrics {
            appLogoImage
                .resizable()
                .frame(width: sizeMetrics.imageSize, height: sizeMetrics.imageSize)
                .modifier(AuthenticationBrandLogoModifier(scale: sizeMetrics.scale,
                                                          hideBrandChrome: hideBrandChrome,
                                                          isOnGradient: isOnGradient))
        } else {
            appLogoImage
                .resizable()
                .scaledToFit()
                .modifier(AuthenticationBrandLogoModifier(scale: 1,
                                                          hideBrandChrome: hideBrandChrome,
                                                          isOnGradient: isOnGradient))
        }
    }
}

/// Applies the brand chrome styling (rounded card with shadows, border and the living aura) to any image,
/// as seen on the authentication start screen.
private struct AuthenticationBrandLogoModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    /// Scale factor relative to the original 158pt design.
    let scale: CGFloat
    /// Set to `true` to skip the brand chrome.
    let hideBrandChrome: Bool
    /// Set to `true` when using on top of `Asset.Images.launchBackground`.
    let isOnGradient: Bool
    
    private let outerShapeShadowColor = Color(red: 0.11, green: 0.11, blue: 0.13)
    private var isLight: Bool {
        colorScheme == .light
    }
    
    /// Extra padding needed to avoid cropping the shadows.
    private var extra: CGFloat {
        32 * scale
    }
    
    /// The shape that the logo is composed on top of.
    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 44 * scale)
    }
    
    func body(content: Content) -> some View {
        if hideBrandChrome {
            content
        } else {
            styledContent(content)
        }
    }
    
    private func styledContent(_ content: Content) -> some View {
        logo(content)
            // The living aura, behind the icon and oversized so colour spills past the edges as a
            // glow. Pure SwiftUI (an AngularGradient that rotates + breathes) so it renders AND
            // animates reliably on device — a Core Animation layer in a SwiftUI background often
            // never starts. Always drawn; the motion is suppressed under Reduce Motion.
            .background {
                GeometryReader { proxy in
                    SiriAura(animated: !reduceMotion)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(2.0)
                        .allowsHitTesting(false)
                }
            }
    }
    
    private func logo(_ content: Content) -> some View {
        content
            .scaleEffect(0.8)
            .clipShape(outerShape)
            .overlay(alignment: .center) {
                outerShape
                    .inset(by: 0.25 * scale)
                    .stroke(.white.opacity(isLight ? 1 : isOnGradient ? 0.9 : 0.25), lineWidth: 0.5 * scale)
                    .blendMode(isLight ? .normal : .overlay)
            }
            .padding(extra)
            .background {
                ZStack {
                    if !isLight, isOnGradient {
                        outerShape
                            .inset(by: 1 * scale)
                            .padding(extra)
                            .shadow(color: .black.opacity(0.5),
                                    radius: 32.91666 * scale,
                                    y: 1.05333 * scale)
                    } else {
                        outerShape
                            .inset(by: 1 * scale)
                            .padding(extra)
                            .shadow(color: outerShapeShadowColor.opacity(isLight ? 0.23 : 0.08),
                                    radius: 16 * scale,
                                    y: 8 * scale)
                        
                        outerShape
                            .inset(by: 1 * scale)
                            .padding(extra)
                            .shadow(color: outerShapeShadowColor.opacity(0.5),
                                    radius: 16 * scale,
                                    y: 8 * scale)
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
            .accessibilityHidden(true)
    }
}

/// A flowing, multi-hue "Apple-Intelligence/Siri"-style glow: an angular (conic) gradient that
/// rotates continuously and breathes, written in pure SwiftUI so it reliably renders AND animates
/// on device. (A Core Animation layer in a SwiftUI `.background` frequently never starts its
/// animation.) The glow is always drawn; `animated` only toggles the motion (for Reduce Motion).
private struct SiriAura: View {
    let animated: Bool
    
    @State private var angle: Double = 0
    @State private var breathing = false
    
    private let auraColors: [Color] = [
        Color(red: 0.20, green: 0.95, blue: 0.55), // Gua green
        Color(red: 0.10, green: 0.80, blue: 0.90), // cyan
        Color(red: 0.30, green: 0.55, blue: 1.00), // blue
        Color(red: 0.65, green: 0.40, blue: 1.00), // purple
        Color(red: 1.00, green: 0.45, blue: 0.70), // pink
        Color(red: 0.20, green: 0.95, blue: 0.55) // back to green
    ]
    
    var body: some View {
        GeometryReader { geometry in
            let dimension = min(geometry.size.width, geometry.size.height)
            
            AngularGradient(gradient: Gradient(colors: auraColors), center: .center)
                // Rotate the whole gradient (more reliably animatable than the `angle:` param) and
                // blur it into a soft round halo so the colour clearly spills around the logo.
                .rotationEffect(.degrees(angle))
                .clipShape(Circle())
                .blur(radius: dimension * 0.11)
                .opacity(breathing ? 1.0 : 0.5)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                angle = 360
            }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        HStack(spacing: 0) {
            AuthenticationStartLogo(hideBrandChrome: false, isOnGradient: false)
                .padding()
            AuthenticationStartLogo(hideBrandChrome: false, isOnGradient: true)
                .padding()
                .background {
                    AuthenticationStartScreenBackgroundImage().offset(y: 70)
                }
                .clipped()
        }
        .background(.compound.bgCanvasDefault)
        
        HStack(spacing: 0) {
            AuthenticationStartLogo(hideBrandChrome: false, isOnGradient: false)
                .padding()
            AuthenticationStartLogo(hideBrandChrome: false, isOnGradient: true)
                .padding()
                .background {
                    AuthenticationStartScreenBackgroundImage().offset(y: 70)
                }
                .clipped()
        }
        .background(.compound.bgCanvasDefault)
        .colorScheme(.dark)
        
        HStack(spacing: 0) {
            AuthenticationStartLogo(size: 54, hideBrandChrome: false, isOnGradient: false)
                .padding()
                .background(.compound.bgCanvasDefault)
            AuthenticationStartLogo(size: 54, hideBrandChrome: false, isOnGradient: false)
                .padding()
                .background(.compound.bgCanvasDefault)
                .colorScheme(.dark)
        }
        .padding(.top)
    }
}
