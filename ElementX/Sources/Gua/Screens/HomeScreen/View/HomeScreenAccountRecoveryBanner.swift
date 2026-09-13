//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// Tells the owner that someone started a delayed recovery of their account, and lets them cancel
/// it. Shown above the room list for as long as the identity service reports one as live. There is
/// no dismiss button: whoever started it may be about to take the account over, and this banner is
/// how the owner finds out in time.
struct HomeScreenAccountRecoveryBanner: View {
    let recovery: PendingAccountRecovery
    var context: HomeScreenViewModel.Context

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.screenAccountRecoveryBannerTitle)
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Self.message(for: recovery, now: .now))
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
            }

            Button {
                context.send(viewAction: .cancelAccountRecovery)
            } label: {
                Text(L10n.screenAccountRecoveryBannerAction)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary, size: .medium))
        }
        .padding(16)
        .background(Color.compound.bgSubtleSecondary)
        .cornerRadius(14)
        .padding(.horizontal, 16)
    }

    /// When it can be finished, in the device's locale and time zone, or that it can be finished
    /// already. A report without the date still says what to do about it.
    static func message(for recovery: PendingAccountRecovery, now: Date) -> String {
        guard let completableAt = recovery.completableAt else {
            return L10n.screenAccountRecoveryBannerMessageGeneric
        }
        guard completableAt > now else {
            return L10n.screenAccountRecoveryBannerMessageNow
        }
        return L10n.screenAccountRecoveryBannerMessageLater(completableAt.formatted(date: .abbreviated, time: .shortened))
    }
}

struct HomeScreenAccountRecoveryBanner_Previews: PreviewProvider {
    static let viewModel = HomeScreenRecoveryKeyConfirmationBanner_Previews.makeViewModel()

    static var previews: some View {
        HomeScreenAccountRecoveryBanner(recovery: .init(completableAt: .now.addingTimeInterval(3 * 24 * 60 * 60),
                                                        expiresAt: .now.addingTimeInterval(10 * 24 * 60 * 60)),
                                        context: viewModel.context)
            .previewDisplayName("Pending")
        HomeScreenAccountRecoveryBanner(recovery: .init(completableAt: .now.addingTimeInterval(-60),
                                                        expiresAt: .now.addingTimeInterval(7 * 24 * 60 * 60)),
                                        context: viewModel.context)
            .previewDisplayName("Ready")
    }
}
