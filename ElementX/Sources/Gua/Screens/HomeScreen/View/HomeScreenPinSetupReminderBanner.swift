//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// Encourages the user to set up two-step verification. Shown above the room list when the account
/// holds no strong factor and the reminder is not snoozed. The primary button opens Settings; the
/// dismiss button snoozes the reminder for a week.
struct HomeScreenPinSetupReminderBanner: View {
    var context: HomeScreenViewModel.Context

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(L10n.screenTwoStepVerificationReminderTitle)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        context.send(viewAction: .dismissPinReminder)
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.compound.iconSecondary)
                            .frame(width: 12, height: 12)
                    }
                }

                Text(L10n.screenTwoStepVerificationReminderMessage)
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
            }

            Button {
                context.send(viewAction: .setUpPinReminder)
            } label: {
                Text(L10n.screenTwoStepVerificationReminderAction)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary, size: .medium))
        }
        .padding(16)
        .background(Color.compound.bgSubtleSecondary)
        .cornerRadius(14)
        .padding(.horizontal, 16)
    }
}
