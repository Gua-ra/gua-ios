//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import UIKit

/// The app's logo with an "Apple-Intelligence/Siri"-style living aura: a flowing, multi-hue
/// conic gradient continuously rotates behind the icon and spills out as a soft glow.
///
/// The motion is driven by **Core Animation** (a `CABasicAnimation` on the gradient layer),
/// not SwiftUI's animation timeline — so it runs reliably whenever the view is on screen.
/// It is disabled when the user prefers reduced motion.
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

    var body: some View {
        logo
            // The animated aura, behind the icon, blurred and slightly oversized so colour
            // spills past the edges as a glow. GeometryReader gives the UIView an explicit
            // frame (a bare UIViewRepresentable in a background would otherwise be 0×0).
            .background {
                if !reduceMotion {
                    GeometryReader { proxy in
                        SiriGlow()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(1.4)
                            .opacity(1.0)
                            .allowsHitTesting(false)
                    }
                }
            }
    }

    private var logo: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .scaleEffect(0.8)
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
            .accessibilityHidden(true)
    }
}

/// A flowing, multi-hue "Apple-Intelligence/Siri"-style glow. A circular conic gradient
/// rotates continuously via Core Animation to give an alive, flammy colour flow.
private struct SiriGlow: UIViewRepresentable {
    func makeUIView(context: Context) -> SiriGlowView { SiriGlowView() }
    func updateUIView(_ uiView: SiriGlowView, context: Context) { }
}

final class SiriGlowView: UIView {
    private let gradient = CAGradientLayer()
    /// Radial alpha mask that fades the colour out toward the edges, giving a soft glow
    /// without SwiftUI's `.blur` (which rasterises the view and would freeze the rotation).
    private let radialMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        isUserInteractionEnabled = false
        backgroundColor = .clear

        gradient.type = .conic
        gradient.colors = [
            UIColor(red: 0.16, green: 0.86, blue: 0.55, alpha: 1).cgColor, // Gua green
            UIColor(red: 0.13, green: 0.74, blue: 0.80, alpha: 1).cgColor, // teal
            UIColor(red: 0.28, green: 0.55, blue: 0.98, alpha: 1).cgColor, // blue
            UIColor(red: 0.62, green: 0.42, blue: 0.98, alpha: 1).cgColor, // purple
            UIColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1).cgColor, // pink
            UIColor(red: 0.16, green: 0.86, blue: 0.55, alpha: 1).cgColor // back to green
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        layer.addSublayer(gradient)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 6
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gradient.add(spin, forKey: "spin")

        // A bright annulus (clear centre → bright at the icon's edge → clear outside) so the
        // colour reads as a glowing ring hugging the logo rather than a hidden disc.
        radialMask.type = .radial
        radialMask.colors = [UIColor.clear.cgColor,
                             UIColor.clear.cgColor,
                             UIColor.white.cgColor,
                             UIColor.white.cgColor,
                             UIColor.clear.cgColor]
        radialMask.locations = [0.0, 0.42, 0.6, 0.78, 1.0]
        radialMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        radialMask.endPoint = CGPoint(x: 1.0, y: 1.0)
        gradient.mask = radialMask
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        // Circular so the rotation reads as a smooth colour flow rather than spinning corners.
        gradient.cornerRadius = min(bounds.width, bounds.height) / 2
        gradient.masksToBounds = true
        gradient.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        radialMask.frame = gradient.bounds
        CATransaction.commit()
    }
}
