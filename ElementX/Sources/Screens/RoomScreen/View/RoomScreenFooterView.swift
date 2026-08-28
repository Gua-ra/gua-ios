//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct RoomScreenFooterView: View {
    let details: RoomScreenFooterViewDetails?
    let mediaProvider: MediaProviderProtocol?
    let callback: (RoomScreenFooterViewAction) -> Void
    
    /// GUA FORK: identity changes are informational, never alarming. Both the pin and the
    /// verification variants share the calm informational styling instead of the critical one.
    private var borderColor: Color {
        switch details {
        case .pinViolation, .verificationViolation:
            .compound.borderInfoSubtle
        case .none:
            Color.compound.bgCanvasDefault
        }
    }

    private var gradient: Gradient {
        switch details {
        case .pinViolation, .verificationViolation:
            .compound.info
        case .none:
            Gradient(colors: [.clear])
        }
    }
    
    var body: some View {
        if let details {
            detailsView(details)
                .highlight(gradient: gradient,
                           borderColor: borderColor,
                           backgroundColor: .compound.bgCanvasDefault)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    @ViewBuilder
    private func detailsView(_ details: RoomScreenFooterViewDetails) -> some View {
        // GUA FORK: WhatsApp-style identity change experience. One informational banner for
        // both variants, acknowledged with a single OK tap. The tap resolves the underlying
        // violation (pins the new identity, or withdraws the stale verification) so sending
        // is never obstructed afterwards.
        switch details {
        case .pinViolation(let member, let learnMoreURL):
            identityChange(member: member, learnMoreURL: learnMoreURL, action: .resolvePinViolation(userID: member.userID))
        case .verificationViolation(let member, let learnMoreURL):
            identityChange(member: member, learnMoreURL: learnMoreURL, action: .resolveVerificationViolation(userID: member.userID))
        }
    }

    private func identityChange(member: RoomMemberProxyProtocol,
                                learnMoreURL: URL,
                                action: RoomScreenFooterViewAction) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                LoadableAvatarImage(url: member.avatarURL,
                                    name: member.disambiguatedDisplayName,
                                    contentID: member.userID,
                                    avatarSize: .user(on: .timeline),
                                    mediaProvider: mediaProvider)

                Text(identityChangeDescriptionWithLearnMoreLink(displayName: member.displayName,
                                                                userID: member.userID,
                                                                url: learnMoreURL))
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textPrimary)
            }

            Button {
                callback(action)
            } label: {
                Text(L10n.actionOk)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary, size: .medium))
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func identityChangeDescriptionWithLearnMoreLink(displayName: String?, userID: String, url: URL) -> AttributedString {
        let linkPlaceholder = "{link}"
        let displayName = displayName ?? fallbackDisplayName(userID)
        var description = AttributedString(UntranslatedL10n.guaIdentityChangeBannerDescription(displayName, linkPlaceholder))

        var linkString = AttributedString(L10n.actionLearnMore)
        linkString.link = url
        linkString.bold()
        description.replace(linkPlaceholder, with: linkString)
        return description
    }
    
    private func fallbackDisplayName(_ userID: String) -> String {
        guard let localpart = userID.components(separatedBy: ":").first else { return userID }
        return String(localpart.trimmingPrefix("@"))
    }
}

struct RoomScreenFooterView_Previews: PreviewProvider, TestablePreview {
    static let bobDetails: RoomScreenFooterViewDetails = .pinViolation(member: RoomMemberProxyMock.mockBob,
                                                                       learnMoreURL: "https://gua.global/help#security-changes")
    static let noNameDetails: RoomScreenFooterViewDetails = .pinViolation(member: RoomMemberProxyMock.mockNoName,
                                                                          learnMoreURL: "https://gua.global/help#security-changes")

    static let verificationViolationDetails: RoomScreenFooterViewDetails = .verificationViolation(member: RoomMemberProxyMock.mockBob,
                                                                                                  learnMoreURL: "https://gua.global/help#security-changes")
    
    static var previews: some View {
        RoomScreenFooterView(details: bobDetails, mediaProvider: MediaProviderMock(configuration: .init())) { _ in }
            .previewDisplayName("With displayname")
        RoomScreenFooterView(details: noNameDetails, mediaProvider: MediaProviderMock(configuration: .init())) { _ in }
            .previewDisplayName("Without displayname")
        RoomScreenFooterView(details: verificationViolationDetails, mediaProvider: MediaProviderMock(configuration: .init())) { _ in }
            .previewDisplayName("Verification Violation")
    }
}
