//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct GuaMessageActionsView: View {
    /// Medium buttons pad 7pt above and below the label, so this keeps each touch target at 44pt.
    private static let minimumLabelHeight: CGFloat = 30
    
    @Environment(\.openURL) private var openURL
    
    let actions: [GuaMessageAction]
    /// Off for a copy that only measures the natural width of the buttons.
    var fillsWidth = true
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.element.rawURL) { index, action in
                Button {
                    openURL(action.urlToOpen)
                } label: {
                    Label(action.label, icon: \.popOut)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: Self.minimumLabelHeight)
                }
                .buttonStyle(.compound(index == 0 ? .primary : .secondary, size: .medium))
                .accessibilityAddTraits(.isLink)
            }
        }
    }
}

struct GuaMessageActionsStack<MessageBody: View>: View {
    let actions: [GuaMessageAction]
    @ViewBuilder let messageBody: MessageBody
    
    var body: some View {
        // A body that renders nothing adds no subview, so no spacing is left above the buttons.
        TimelineBubbleLayout(spacing: 8) {
            messageBody
            GuaMessageActionsView(actions: actions)
                // The bubble is one accessibility element: the labels join its text and its named actions open them.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(actions.map(\.label).joined(separator: ", "))
                .timelineBubbleLayoutSize(.bubbleWidth(mode: .rendering))
            // Widens the bubble only as far as the buttons' natural width.
            GuaMessageActionsView(actions: actions, fillsWidth: false)
                .timelineBubbleLayoutSize(.bubbleWidth(mode: .layout))
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

struct GuaMessageActionsView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    
    static var previews: some View {
        bubbles
            .previewDisplayName("Light")
        bubbles
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark")
    }
    
    static var bubbles: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextRoomTimelineView(timelineItem: textItem(html: "<strong>August statement</strong><br>Total: <strong>$10.00</strong><br><a href=\"https://bills.example.org/statement/2026-08\">View statement</a>",
                                                        actions: [("View statement", "https://bills.example.org/statement/2026-08")]))
            
            TextRoomTimelineView(timelineItem: textItem(html: "Shipped: <a href=\"https://shop.example.org/orders/42\">order</a>, <a href=\"https://shop.example.org/track/42\">tracking</a>, <a href=\"https://shop.example.org/help\">help</a>.",
                                                        actions: [("Track parcel", "https://shop.example.org/track/42"),
                                                                  ("View order", "https://shop.example.org/orders/42"),
                                                                  ("Get help", "https://shop.example.org/help")]))
            
            TextRoomTimelineView(timelineItem: textItem(html: "<a href=\"https://shop.example.org/orders/42\">View order</a>",
                                                        actions: [("View order", "https://shop.example.org/orders/42")]))
            
            NoticeRoomTimelineView(timelineItem: noticeItem(html: "Build finished<br><a href=\"https://ci.example.org/builds/7\">View build</a>",
                                                            actions: [("View build", "https://ci.example.org/builds/7")]))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .environmentObject(viewModel.context)
    }
    
    private static func textItem(html: String, actions: [(label: String, url: String)]) -> TextRoomTimelineItem {
        let content = TextRoomTimelineItemContent(body: "", formattedBody: builder.fromHTML(html), formattedBodyHTMLString: html)
        
        return TextRoomTimelineItem(id: .randomEvent,
                                    timestamp: .mock,
                                    isOutgoing: false,
                                    isEditable: false,
                                    canBeRepliedTo: true,
                                    sender: .init(id: "@bills:example.org", displayName: "Bills"),
                                    content: content.addingGuaMessageActions(latestJSON: eventJSON(msgType: "m.text", html: html, actions: actions)))
    }
    
    private static func noticeItem(html: String, actions: [(label: String, url: String)]) -> NoticeRoomTimelineItem {
        let content = NoticeRoomTimelineItemContent(body: "", formattedBody: builder.fromHTML(html), formattedBodyHTMLString: html)
        
        return NoticeRoomTimelineItem(id: .randomEvent,
                                      timestamp: .mock,
                                      isOutgoing: false,
                                      isEditable: false,
                                      canBeRepliedTo: true,
                                      sender: .init(id: "@ci:example.org", displayName: "CI"),
                                      content: content.addingGuaMessageActions(latestJSON: eventJSON(msgType: "m.notice", html: html, actions: actions)))
    }
    
    private static var builder: AttributedStringBuilder {
        AttributedStringBuilder(cacheKey: "preview", mentionBuilder: MentionBuilder())
    }
    
    private static func eventJSON(msgType: String, html: String, actions: [(label: String, url: String)]) -> String? {
        let messageContent: [String: Any] = ["msgtype": msgType,
                                             "body": "",
                                             "format": "org.matrix.custom.html",
                                             "formatted_body": html,
                                             GuaMessageActionParser.contentKey: actions.map { ["type": "open_url", "label": $0.label, "url": $0.url] }]
        return (try? JSONSerialization.data(withJSONObject: ["content": messageContent])).flatMap { String(data: $0, encoding: .utf8) }
    }
}
