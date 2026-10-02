//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftUI

struct RoomHeaderView: View {
    let roomName: String
    var roomSubtitle: String?
    let roomAvatar: RoomAvatar
    var dmRecipientVerificationState: UserIdentityVerificationState?
    
    let mediaProvider: MediaProviderProtocol?
    
    var body: some View {
        if #available(iOS 26.0, *) {
            // Never propose an unbounded width to the principal toolbar item on iOS 26: it reaches
            // NSLayoutConstraint and aborts with 'NSLayoutConstraint constant is not finite!'.
            // https://github.com/element-hq/element-x-ios/issues/4180
            // Leading alignment comes from .toolbarRole(RoomHeaderView.toolbarRole) on the screen instead.
            content
        } else if ProcessInfo.isRunningAccessibilityTests {
            // Accessibility tests scale up the dynamic size in real time which may break the view
            content
        } else {
            content
                // Take up as much space as possible, with a leading alignment for use in the principal toolbar position
                .frame(idealWidth: .greatestFiniteMagnitude, maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var content: some View {
        HStack(spacing: 8) {
            avatarImage
                .accessibilityHidden(true)
            
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(roomName)
                        .lineLimit(1)
                        .font(.compound.bodyLGSemibold)
                        .accessibilityIdentifier(A11yIdentifiers.roomScreen.name)
                    if let roomSubtitle {
                        Text(roomSubtitle)
                            .lineLimit(1)
                            .font(.compound.bodyXS)
                            .foregroundStyle(.compound.textSecondary)
                    }
                }
                
                if let dmRecipientVerificationState {
                    VerificationBadge(verificationState: dmRecipientVerificationState)
                }
            }
        }
    }
    
    private var avatarImage: some View {
        RoomAvatarImage(avatar: roomAvatar,
                        avatarSize: .room(on: .timeline),
                        mediaProvider: mediaProvider)
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.avatar)
    }
}

extension RoomHeaderView {
    /// The toolbar role to apply on any screen that shows this view in a `.principal` toolbar item.
    ///
    /// On iOS 26 the editor role leading-aligns the item. On iOS 18 and lower it causes an animation
    /// glitch with the back button, so it is not used there.
    static var toolbarRole: ToolbarRole {
        if #available(iOS 26.0, *) {
            .editor
        } else {
            .automatic
        }
    }
}

struct RoomHeaderView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 8) {
            makeHeader(avatarURL: nil, verificationState: .notVerified)
            makeHeader(avatarURL: .mockMXCAvatar, verificationState: .notVerified)
            makeHeader(avatarURL: .mockMXCAvatar, verificationState: .verified)
            makeHeader(avatarURL: .mockMXCAvatar, verificationState: .verificationViolation)
            makeHeader(avatarURL: .mockMXCAvatar,
                       roomSubtitle: "Subtitle",
                       verificationState: .verified)
        }
        .previewLayout(.sizeThatFits)
    }
    
    static func makeHeader(avatarURL: URL?,
                           roomSubtitle: String? = nil,
                           verificationState: UserIdentityVerificationState) -> some View {
        RoomHeaderView(roomName: "Some Room name",
                       roomSubtitle: roomSubtitle,
                       roomAvatar: .room(id: "1",
                                         name: "Some Room Name",
                                         avatarURL: avatarURL),
                       dmRecipientVerificationState: verificationState,
                       mediaProvider: MediaProviderMock(configuration: .init()))
            .padding()
    }
}
