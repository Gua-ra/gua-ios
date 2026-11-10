//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

extension TimelineFixtures {
    /// A group chat with every element that is drawn straight on the timeline and so gets a capsule over a background.
    static var chatBackgroundShowcase: [RoomTimelineItemProtocol] {
        let helena = TimelineItemSender(id: "@helena:gua.global", displayName: "Helena")
        let jacob = TimelineItemSender(id: "@jacob:gua.global", displayName: "Jacob", isDisplayNameAmbiguous: true)
        let me = TimelineItemSender(id: "@me:gua.global", displayName: "Me")
        
        func eventID(_ index: Int) -> TimelineItemIdentifier {
            .event(uniqueID: .init("ChatBackgroundShowcase.\(index)"), eventOrTransactionID: .eventID("ChatBackgroundShowcase.\(index)"))
        }
        
        return [
            TimelineStartRoomTimelineItem(name: "Weekend plans"),
            SeparatorRoomTimelineItem(id: .virtual(uniqueID: .init("ChatBackgroundShowcase.today")), timestamp: .mock),
            StateRoomTimelineItem(id: eventID(0),
                                  body: UntranslatedL10n.guaChatThemeNoticeChanged("Helena"),
                                  timestamp: .mock,
                                  isOutgoing: false,
                                  isEditable: false,
                                  canBeRepliedTo: false,
                                  sender: helena),
            TextRoomTimelineItem(id: eventID(1),
                                 timestamp: .mock,
                                 isOutgoing: false,
                                 isEditable: false,
                                 canBeRepliedTo: true,
                                 sender: helena,
                                 content: .init(body: "New background for the trip chat. What do you think?"),
                                 properties: RoomTimelineItemProperties(reactions: [
                                     AggregatedReaction(accountOwnerID: me.id, key: "😍", senders: [ReactionSender(id: me.id, timestamp: .mock)]),
                                     AggregatedReaction(accountOwnerID: me.id, key: "🙌", senders: [ReactionSender(id: jacob.id, timestamp: .mock)])
                                 ])),
            ReadMarkerRoomTimelineItem(id: .virtual(uniqueID: .init("ChatBackgroundShowcase.readMarker"))),
            TextRoomTimelineItem(id: eventID(2),
                                 timestamp: .mock,
                                 isOutgoing: false,
                                 isEditable: false,
                                 canBeRepliedTo: true,
                                 sender: jacob,
                                 content: .init(body: "Love it. Saturday at 10?")),
            TextRoomTimelineItem(id: eventID(3),
                                 timestamp: .mock,
                                 isOutgoing: true,
                                 isEditable: true,
                                 canBeRepliedTo: true,
                                 sender: me,
                                 content: .init(body: "Saturday works, see you there!"),
                                 properties: RoomTimelineItemProperties(orderedReadReceipts: [ReadReceipt(userID: helena.id, formattedTimestamp: nil),
                                                                                              ReadReceipt(userID: jacob.id, formattedTimestamp: nil)]))
        ]
    }
}
