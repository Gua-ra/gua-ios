//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ModerationAndSafetySettingsScreenViewModelAction {
    case blockedUsers
}

struct ModerationAndSafetySettingsScreenViewState: BindableState {
    var hideInviteAvatars: Bool
    var isWaitingHideInviteAvatars = false
    
    var timelineMediaVisibility: TimelineMediaVisibility
    var isWaitingTimelineMediaVisibility = false
    
    var showBlockedUsers = false
}

enum ModerationAndSafetySettingsScreenViewAction {
    case updateHideInviteAvatars(Bool)
    case updateTimelineMediaVisibility(TimelineMediaVisibility)
    case blockedUsers
}
