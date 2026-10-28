//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit

enum SettingsScreenViewModelAction: Equatable {
    case close
    case userDetails
    case manageAccount(url: URL)
    case analytics
    case appLock
    case reportBug
    case about
    case blockedUsers
    case notifications
    case advancedSettings
    case developerOptions
    case logout
    case deactivateAccount
    case twoStepVerification
    case changePhoneNumber
    case findFriends
}

struct SettingsScreenViewState: BindableState {
    var deviceID: String?
    var userID: String
    var accountProfileURL: URL?
    var accountSessionsListURL: URL?
    var showAccountDeactivation: Bool
    var userAvatarURL: URL?
    var userDisplayName: String?
    var showDeveloperOptions: Bool
    
    var userLocalpart: String {
        userID.hasPrefix("@") ? String(userID.dropFirst().prefix { $0 != ":" }) : userID
    }
    
    var showBlockedUsers = false
    let showAnalyticsSettings: Bool
    
    let isBugReportServiceEnabled: Bool
    
    var bindings: SettingsScreenViewStateBindings
}

struct SettingsScreenViewStateBindings {
    private let appSettings: AppSettings
    
    var isPresentingAccountDeactivationConfirmation = false
    
    var appAppearance: AppAppearance {
        get { appSettings.appAppearance }
        set { appSettings.appAppearance = newValue }
    }
    
    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }
}

enum SettingsScreenViewAction {
    case close
    case userDetails
    case analytics
    case appLock
    case reportBug
    case about
    case blockedUsers
    case manageAccount(url: URL)
    case notifications
    case enableDeveloperOptions
    case developerOptions
    case advancedSettings
    case logout
    case deactivateAccount
    case twoStepVerification
    case changePhoneNumber
    case findFriends
}
