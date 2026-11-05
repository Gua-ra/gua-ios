//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SFSafeSymbols
import SwiftUI

struct SettingsScreen: View {
    @Bindable var context: SettingsScreenViewModel.Context
    
    var body: some View {
        Form {
            userSection
            
            findFriendsSection
            
            if context.viewState.showAddAccountButton {
                addAccountSection
            }
            
            accountSettingsSection
            
            signOutSection
            
            appSettingsSection
        }
        .compoundList()
        .navigationTitle(L10n.commonSettings)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(context.viewState.navigationBarVisibility, for: .navigationBar)
        .toolbar { toolbar }
        .sheet(isPresented: $context.isPresentingStatusPicker) {
            SettingsScreenUserStatusPickerView { action in
                context.send(viewAction: .userStatus(action))
            }
            .presentationDetents([.medium])
            .presentationBackground(.compound.bgCanvasDefault)
        }
    }
    
    private var userSection: some View {
        Section {
            ListRow(kind: .custom {
                Button {
                    context.send(viewAction: .userDetails)
                } label: {
                    HStack(spacing: 12) {
                        LoadableAvatarImage(url: context.viewState.userProfile.avatarURL,
                                            name: context.viewState.userProfile.displayName,
                                            contentID: context.viewState.userProfile.id,
                                            avatarSize: .user(on: .settings),
                                            mediaProvider: context.mediaProvider)
                            .accessibilityHidden(true)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.viewState.userProfile.displayName ?? "")
                                .font(.compound.headingMD)
                                .foregroundColor(.compound.textPrimary)
                            
                            Text(context.viewState.userLocalpart)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textSecondary)
                        }
                        
                        Spacer()
                        
                        ListRowAccessory.navigationLink
                    }
                    .padding(.horizontal, ListRowPadding.horizontal)
                    .padding(.vertical, 8)
                }
            })
            
            if context.viewState.showUserStatusInput {
                SettingsScreenUserStatusRow(mode: context.viewState.userStatusRowMode) { action in
                    context.send(viewAction: .userStatus(action))
                }
            }
        }
    }
    
    private var findFriendsSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenFindFriendsTitle,
                                    icon: \.userAdd),
                    kind: .navigationLink {
                        context.send(viewAction: .findFriends)
                    })
        }
    }
    
    private var addAccountSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenSettingsAddAccount,
                                    icon: \.plus),
                    kind: .navigationLink {
                        context.send(viewAction: .addAccount)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.addAccount)
        }
    }
    
    private var accountSettingsSection: some View {
        Section {
            if let url = context.viewState.accountProfileURL {
                ListRow(label: .default(title: UntranslatedL10n.actionManageAccountAndDevices,
                                        icon: \.userProfile),
                        kind: .button {
                            context.send(viewAction: .manageAccount(url: url))
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.account)
            }
            
            ListRow(label: .default(title: L10n.screenTwoStepVerificationTitle,
                                    icon: \.key),
                    kind: .navigationLink {
                        context.send(viewAction: .twoStepVerification)
                    })
            
            ListRow(label: .default(title: L10n.screenChangePhoneTitle,
                                    icon: \.edit),
                    kind: .navigationLink {
                        context.send(viewAction: .changePhoneNumber)
                    })
            
            if context.viewState.showLinkNewDeviceButton {
                ListRow(label: .default(title: L10n.commonLinkNewDevice,
                                        icon: \.devices),
                        kind: .navigationLink {
                            context.send(viewAction: .linkNewDevice)
                        })
            }
            
            ListRow(label: .default(title: L10n.screenNotificationSettingsTitle,
                                    icon: \.notifications),
                    kind: .navigationLink {
                        context.send(viewAction: .notifications)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.notifications)
            
            ListRow(label: .default(title: UntranslatedL10n.commonModerationAndSafety,
                                    icon: \.admin),
                    kind: .navigationLink {
                        context.send(viewAction: .moderationAndSafety)
                    })
            
            if context.viewState.isBugReportServiceEnabled {
                ListRow(label: .default(title: L10n.commonReportAProblem,
                                        icon: \.chatProblem),
                        kind: .navigationLink {
                            context.send(viewAction: .reportBug)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.reportBug)
            }
        } header: {
            Text(UntranslatedL10n.commonAccountSettings)
                .compoundListSectionHeader()
        }
    }
    
    private var signOutSection: some View {
        Section {
            ListRow(label: .action(title: UntranslatedL10n.guaSettingsSignOut,
                                   icon: \.close,
                                   role: .destructive),
                    kind: .button {
                        context.send(viewAction: .logout)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.logout)
            
            if context.viewState.showAccountDeactivation {
                ListRow(label: .action(title: UntranslatedL10n.actionDeleteAccount,
                                       icon: \.delete,
                                       role: .destructive),
                        kind: .navigationLink {
                            context.send(viewAction: .deactivateAccount)
                        })
            }
        }
    }
    
    private var appSettingsSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenHomeTabSpaces,
                                    description: UntranslatedL10n.guaSettingsSpacesDescription,
                                    icon: \.space),
                    kind: .toggle($context.isSpacesEnabled))
                .onChange(of: context.isSpacesEnabled) {
                    context.send(viewAction: .toggleSpaces)
                }
                .accessibilityIdentifier(A11yIdentifiers.settingsScreen.spaces)
            
            ListRow(label: .default(title: L10n.commonAppearance,
                                    icon: \.darkMode),
                    kind: .picker(selection: $context.appAppearance,
                                  items: AppAppearance.allCases.map { (title: $0.name, tag: $0) }))
            
            ListRow(label: .default(title: UntranslatedL10n.commonMediaUploadQuality,
                                    icon: \.image),
                    kind: .navigationLink {
                        context.send(viewAction: .mediaUploadQuality)
                    })
            
            ListRow(label: .default(title: L10n.commonScreenLock,
                                    icon: \.lock),
                    kind: .navigationLink {
                        context.send(viewAction: .appLock)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.screenLock)
            
            ListRow(label: .default(title: L10n.commonLocationSharing,
                                    icon: \.locationPin),
                    kind: .navigationLink {
                        context.send(viewAction: .locationSharing)
                    })
            
            if context.viewState.showAnalyticsSettings {
                ListRow(label: .default(title: L10n.commonAnalytics,
                                        icon: \.chart),
                        kind: .navigationLink {
                            context.send(viewAction: .analytics)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.analytics)
            }
            
            if context.viewState.showLabsSettings {
                ListRow(label: .default(title: L10n.screenAdvancedSettingsLabs,
                                        icon: \.labs),
                        kind: .navigationLink {
                            context.send(viewAction: .labs)
                        })
            }
            
            ListRow(label: .default(title: L10n.commonAbout,
                                    icon: \.info),
                    kind: .navigationLink {
                        context.send(viewAction: .about)
                    })
                    .accessibilityIdentifier(A11yIdentifiers.settingsScreen.about)
            
            if context.viewState.showDeveloperOptions {
                ListRow(label: .default(title: L10n.commonDeveloperOptions,
                                        icon: \.code),
                        kind: .navigationLink {
                            context.send(viewAction: .developerOptions)
                        })
                        .accessibilityIdentifier(A11yIdentifiers.settingsScreen.developerOptions)
            }
        } header: {
            Text(UntranslatedL10n.commonAppSettings)
                .compoundListSectionHeader()
        } footer: {
            versionSection
        }
    }
    
    private var versionSection: some View {
        VStack(spacing: 0) {
            versionText
                .frame(maxWidth: .infinity)
            
            if let deviceID = context.viewState.deviceID {
                Text(deviceID)
            }
        }
        .compoundListSectionFooter()
        .textSelection(.enabled)
        .padding(.top, 24)
        .onTapGesture(count: 7) {
            context.send(viewAction: .enableDeveloperOptions)
        }
    }
    
    private var versionText: Text {
        // Let's not snapshot a changing version string.
        let shortVersion = ProcessInfo.isRunningTests ? "0.0.0" : InfoPlistReader.main.bundleShortVersionString
        let version = ProcessInfo.isRunningTests ? "1" : InfoPlistReader.main.bundleVersion
        return Text(L10n.settingsVersionNumber(shortVersion, version))
    }
    
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ToolbarButton(role: .close) { context.send(viewAction: .close) }
                .accessibilityIdentifier(A11yIdentifiers.settingsScreen.done)
        }
    }
}

private extension AppAppearance {
    var name: String {
        switch self {
        case .system:
            L10n.themeSystem
        case .light:
            L10n.themeLight
        case .dark:
            L10n.themeDark
        }
    }
}

// MARK: - Previews

@available(iOS 26.0, *)
struct SettingsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let bugReportDisabledViewModel = makeViewModel(isBugReportServiceEnabled: false)
    static let guaMarketingViewModel = makeViewModel(userID: "@anacosta:gua", displayName: "Ana Costa", enablesFeatureFlags: false)
    
    static var previews: some View {
        ElementNavigationStack {
            SettingsScreen(context: guaMarketingViewModel.context)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .snapshotPreferences(expect: guaMarketingViewModel.context.observe(\.viewState.accountProfileURL).map { $0 != nil })
        .previewDisplayName("GuaMarketingAjustes")
        
        ElementNavigationStack {
            SettingsScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.accountProfileURL).map { $0 != nil })
        .frame(height: 1500)
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Default")
        
        ElementNavigationStack {
            SettingsScreen(context: bugReportDisabledViewModel.context)
        }
        .snapshotPreferences(expect: bugReportDisabledViewModel.context.observe(\.viewState.accountProfileURL).map { $0 != nil })
        .frame(height: 1450)
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Bug report disabled")
    }
    
    static func makeViewModel(isBugReportServiceEnabled: Bool = true,
                              userID: String = "@alice:example.com",
                              displayName: String = "Alice Liddell",
                              enablesFeatureFlags: Bool = true) -> SettingsScreenViewModel {
        let userSettings = UserSettings.mock(userID: userID)
        userSettings.app.multiAccountEnabled = enablesFeatureFlags
        userSettings.app.linkNewDeviceEnabled = enablesFeatureFlags
        let clientProxy = ClientProxyMock(.init(userID: userID,
                                                deviceID: "AAAAAAAAAAA",
                                                displayName: displayName,
                                                status: .mockFocussing))
        let userSession = UserSessionMock(.init(clientProxy: clientProxy,
                                                userSettings: userSettings))
        return SettingsScreenViewModel(userSession: userSession,
                                       spacesSetting: SpacesSetting(clientProxy: clientProxy, appSettings: userSettings.app),
                                       isBugReportServiceEnabled: isBugReportServiceEnabled,
                                       isInSecondaryWindow: false,
                                       userIndicatorController: UserIndicatorControllerMock())
    }
}
