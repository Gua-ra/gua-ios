//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// No dismiss button: this banner is how the owner learns that someone may be taking over the account.
struct HomeScreenAccountRecoveryBanner: View {
    let recovery: PendingAccountRecovery
    var context: HomeScreenViewModel.Context

    @State private var reachedCompletableAt = Date.distantPast

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.screenAccountRecoveryBannerTitle)
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Self.message(for: recovery, now: max(reachedCompletableAt, .now)))
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
                    .task(id: recovery.completableAt) {
                        guard let completableAt = recovery.completableAt, completableAt > .now else { return }
                        try? await Task.sleep(for: .seconds(completableAt.timeIntervalSinceNow))
                        guard !Task.isCancelled else { return }
                        reachedCompletableAt = completableAt
                    }
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

    /// The date is deliberately coarse: a clock time would reveal when the account was last used.
    static func message(for recovery: PendingAccountRecovery, now: Date) -> String {
        guard let completableAt = recovery.completableAt else {
            return L10n.screenAccountRecoveryBannerMessageGeneric
        }
        guard completableAt > now else {
            return L10n.screenAccountRecoveryBannerMessageNow
        }
        return L10n.screenAccountRecoveryBannerMessageLater(completableAt.formatted(date: .long, time: .omitted))
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
