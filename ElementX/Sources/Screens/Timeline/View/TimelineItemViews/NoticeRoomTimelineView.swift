//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NoticeRoomTimelineView: View, TextBasedRoomTimelineViewProtocol {
    let timelineItem: NoticeRoomTimelineItem
    
    var body: some View {
        TimelineStyler(timelineItem: timelineItem) {
            if timelineItem.content.actions.isEmpty {
                label(trailingReservedSize: timelineItem.trailingReservedSize)
            } else {
                // GUA FORK: the send info sits under the buttons, so nothing is reserved for it in the text.
                GuaMessageActionsStack(actions: timelineItem.content.actions) {
                    if timelineItem.content.hasBubbleBody {
                        label(trailingReservedSize: .zero)
                    }
                }
            }
        }
    }
    
    private func label(trailingReservedSize: CGSize) -> some View {
        // Spacing: 6 = label spacing - formatted text padding
        
        Label {
            if let attributedString = timelineItem.content.bubbleFormattedBody {
                FormattedBodyText(attributedString: attributedString,
                                  trailingReservedSize: trailingReservedSize)
            } else {
                FormattedBodyText(text: timelineItem.content.body,
                                  trailingReservedSize: trailingReservedSize)
            }
        } icon: {
            CompoundIcon(\.info, size: .small, relativeTo: .compound.bodyLG)
                .foregroundColor(.compound.iconSecondary)
        }
        .labelStyle(.custom(spacing: 6.0, alignment: .top))
        .padding(.leading, 4) // Trailing padding is provided by FormattedBodyText
    }
}

struct NoticeRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    
    static var previews: some View {
        body.environmentObject(viewModel.context)
    }
    
    static var body: some View {
        VStack(alignment: .leading, spacing: 20.0) {
            NoticeRoomTimelineView(timelineItem: itemWith(text: "Short loin ground round tongue hamburger, fatback salami shoulder. Beef turkey sausage kielbasa strip steak. Alcatra capicola pig tail pancetta chislic.",
                                                          timestamp: .mock,
                                                          senderId: "Bob"))
            
            NoticeRoomTimelineView(timelineItem: itemWith(text: "Some other text",
                                                          timestamp: .mock,
                                                          senderId: "Anne"))
        }
    }
    
    private static func itemWith(text: String, timestamp: Date, senderId: String) -> NoticeRoomTimelineItem {
        NoticeRoomTimelineItem(id: .randomEvent,
                               timestamp: timestamp,
                               isOutgoing: false,
                               isEditable: false,
                               canBeRepliedTo: true,
                               sender: .init(id: senderId),
                               content: .init(body: text))
    }
}
