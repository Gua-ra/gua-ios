//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftUI

struct HomeScreenRecoveryKeyConfirmationBanner: View {
    enum State {
        case setUpRecovery, recoveryOutOfSync

        /// The action the banner's button sends. Lives on the state, not the view, so a test can
        /// assert it without standing up SwiftUI.
        var primaryAction: HomeScreenViewAction {
            switch self {
            case .setUpRecovery: .setupRecovery
            // GUA FORK: this must stay .confirmRecoveryKey. It routes to finishEncryptionSetup(),
            // which tries every repair that keeps the backup intact and only offers the reset when
            // there is genuinely no other way. Pointing it at .resetEncryption sends every tap
            // straight to the destructive screen and leaves the staged path dead code.
            case .recoveryOutOfSync: .confirmRecoveryKey
            }
        }
    }

    let state: State
    var context: HomeScreenViewModel.Context
    @SwiftUI.State private var isWorking = false
    
    var title: String {
        switch state {
        case .setUpRecovery: L10n.bannerSetUpRecoveryTitle
        // GUA FORK: this state means the device cannot secure messages yet, and the fix is a
        // reset it performs itself. Nobody has a recovery key to confirm, because Gua never
        // shows one, so asking for one is a dead end dressed up as an instruction.
        case .recoveryOutOfSync: UntranslatedL10n.guaEncryptionRepairTitle
        }
    }

    var message: String {
        switch state {
        case .setUpRecovery: L10n.bannerSetUpRecoveryContent
        case .recoveryOutOfSync: UntranslatedL10n.guaEncryptionRepairMessage
        }
    }

    var actionTitle: String {
        switch state {
        case .setUpRecovery: L10n.bannerSetUpRecoverySubmit
        case .recoveryOutOfSync: UntranslatedL10n.guaEncryptionRepairAction
        }
    }

    var primaryAction: HomeScreenViewAction {
        state.primaryAction
    }
    
    var body: some View {
        VStack(spacing: 16) {
            content
            buttons
        }
        .padding(16)
        .background(Color.compound.bgSubtleSecondary)
        .cornerRadius(14)
        .padding(.horizontal, 16)
    }
    
    var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title)
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if state == .setUpRecovery {
                    Button {
                        context.send(viewAction: .skipRecoveryKeyConfirmation)
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.compound.iconSecondary)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            
            Text(message)
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
        }
    }
    
    var buttons: some View {
        VStack(spacing: 16) {
            Button {
                // GUA FORK: the repair runs off-screen and can take a moment, so the button has to
                // change the instant it is pressed. Without this a tap looked like nothing at all
                // happened for several seconds, which reads as a dead button.
                isWorking = true
                context.send(viewAction: primaryAction)
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView()
                            .tint(.compound.iconOnSolidPrimary)
                    }
                    Text(isWorking ? UntranslatedL10n.guaEncryptionRepairActionInProgress : actionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(isWorking)
            .buttonStyle(.compound(.primary, size: .medium))
            .accessibilityIdentifier(A11yIdentifiers.homeScreen.recoveryKeyConfirmationBannerContinue)
            
            // GUA FORK: no second button. It used to offer "Forgot your recovery key?" beside a
            // prompt to enter one, which is two ways of asking about a secret the user has never
            // seen. The primary action now performs the reset directly, so there is one tap and
            // nothing to remember.
        }
    }
}

struct HomeScreenRecoveryKeyConfirmationBanner_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    
    static var previews: some View {
        HomeScreenRecoveryKeyConfirmationBanner(state: .setUpRecovery,
                                                context: viewModel.context)
            .previewDisplayName("Set up recovery")
        HomeScreenRecoveryKeyConfirmationBanner(state: .recoveryOutOfSync,
                                                context: viewModel.context)
            .previewDisplayName("Out of sync")
    }
    
    static func makeViewModel() -> HomeScreenViewModel {
        let clientProxy = ClientProxyMock(.init(userID: "@alice:example.com",
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loading))))
        
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        
        return HomeScreenViewModel(userSession: userSession,
                                   selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                   appSettings: ServiceLocator.shared.settings,
                                   analyticsService: ServiceLocator.shared.analytics,
                                   notificationManager: NotificationManagerMock(),
                                   userIndicatorController: ServiceLocator.shared.userIndicatorController)
    }
}
