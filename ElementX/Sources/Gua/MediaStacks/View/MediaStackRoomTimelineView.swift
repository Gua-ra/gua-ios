//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct MediaStackRoomTimelineView: View {
    private static let fallbackPositions = MediaStackPositions()
    
    @Environment(\.timelineContext) private var context
    @EnvironmentObject private var timelineContext: TimelineViewModel.Context
    @Environment(\.mediaStackDeliveryStatus) private var deliveryStatus
    
    let timelineItem: MediaStackRoomTimelineItem
    
    private var positions: MediaStackPositions {
        context?.viewState.mediaStackPositions ?? Self.fallbackPositions
    }
    
    var body: some View {
        TimelineStyler(timelineItem: timelineItem) {
            VStack(alignment: timelineItem.isOutgoing ? .trailing : .leading, spacing: 6) {
                header
                MediaStackCardsView(stack: timelineItem, positions: positions)
                caption
            }
        }
    }
    
    private var header: some View {
        HStack(spacing: 4) {
            CompoundIcon(\.grid, size: .custom(14), relativeTo: .compound.bodySMSemibold)
            Text(timelineItem.countDescription)
        }
        .font(.compound.bodySMSemibold)
        .foregroundStyle(.compound.textSecondary)
        .contentShape(MediaStackHeaderHitShape())
        .gesture(MediaStackTapGesture(isEnabled: context?.viewState.messageSelection.isActive != true) {
            context?.send(viewAction: .mediaStackHeaderTapped(stackID: timelineItem.id))
        })
    }
    
    /// Shown under the same `hasMediaCaption` test the styler uses to hand this bubble the send info.
    @ViewBuilder
    private var caption: some View {
        if let formattedCaption = timelineItem.formattedMediaCaption, timelineItem.hasMediaCaption {
            captionBubble(FormattedBodyText(attributedString: formattedCaption,
                                            trailingReservedSize: timelineItem.trailingReservedSize))
        } else if let caption = timelineItem.mediaCaption, timelineItem.hasMediaCaption {
            captionBubble(FormattedBodyText(text: caption,
                                            trailingReservedSize: timelineItem.trailingReservedSize))
        }
    }
    
    private func captionBubble(_ text: some View) -> some View {
        text
            .frame(width: MediaStackCardsView.cardSize.width - 16, alignment: .leading)
            .timelineItemSendInfo(timelineItem: timelineItem, adjustedDeliveryStatus: deliveryStatus, context: timelineContext)
            .accessibilityHidden(true) // Read as part of the stack.
            .bubbleBackground(isOutgoing: timelineItem.isOutgoing,
                              insets: .init(top: 8, leading: 8, bottom: 8, trailing: 8),
                              color: timelineItem.isOutgoing ? .compound._bgBubbleOutgoing : .compound._bgBubbleIncoming)
    }
}

/// At least 44 points tall to tap, without pushing the cards away or widening the stack's accessibility frame.
private nonisolated struct MediaStackHeaderHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -14))
    }
}

extension EnvironmentValues {
    /// The delivery status the styler shows, for a captioned stack's send info in its caption bubble.
    @Entry var mediaStackDeliveryStatus: TimelineItemDeliveryStatus?
}

nonisolated extension MediaStackRoomTimelineItem {
    /// A mix of photos and videos counts items, as iMessage words it.
    var countDescription: String {
        switch kind {
        case .photos: UntranslatedL10n.guaMediaStackPhotos(members.count)
        case .videos: UntranslatedL10n.guaMediaStackVideos(members.count)
        case .items: UntranslatedL10n.guaMediaStackItems(members.count)
        }
    }
    
    var removeConfirmationTitle: String {
        switch kind {
        case .photos: UntranslatedL10n.guaMediaStackRemovePhotosTitle(members.count)
        case .videos: UntranslatedL10n.guaMediaStackRemoveVideosTitle(members.count)
        case .items: UntranslatedL10n.guaMediaStackRemoveItemsTitle(members.count)
        }
    }
    
    func positionDescription(at index: Int) -> String {
        if let duration = members[index].duration {
            UntranslatedL10n.guaMediaStackA11yVideoPosition(index + 1, members.count, MediaStackDuration.formatted(duration))
        } else {
            UntranslatedL10n.guaMediaStackA11yPhotoPosition(index + 1, members.count)
        }
    }
}

extension View {
    func mediaStackAccessibility(_ stack: MediaStackRoomTimelineItem) -> some View {
        modifier(MediaStackAccessibilityModifier(stack: stack))
    }
}

private struct MediaStackAccessibilityModifier: ViewModifier {
    @Environment(\.timelineContext) private var context
    @Environment(\.shouldAutomaticallyLoadImages) private var shouldAutomaticallyLoadImages
    
    let stack: MediaStackRoomTimelineItem
    
    private var positions: MediaStackPositions? {
        context?.viewState.mediaStackPositions
    }
    
    private var frontIndex: Int {
        positions?.frontIndex(of: stack) ?? 0
    }
    
    private var value: String {
        let deliveryState: String? = switch stack.properties.deliveryStatus {
        case .sendingFailed: L10n.commonSendingFailed
        case .sending: L10n.commonSending
        case .sent, .none: nil
        }
        
        return [stack.positionDescription(at: frontIndex), stack.mediaCaption, stack.localizedSendInfo, deliveryState]
            .compactMap { $0?.isBlank == false ? $0 : nil }
            .joined(separator: ", ")
    }
    
    private var label: String {
        [stack.sender.displayName ?? stack.sender.id.guaDisplayHandle, stack.countDescription].joined(separator: ", ")
    }
    
    func body(content: Content) -> some View {
        let element = content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        
        // Like the cards, the actions are off while messages are being selected.
        if context?.viewState.messageSelection.isActive == true {
            element
        } else {
            actions(on: element)
        }
    }
    
    private func actions(on element: some View) -> some View {
        element
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: positions?.page(stack, by: 1)
                case .decrement: positions?.page(stack, by: -1)
                @unknown default: break
                }
            }
            .accessibilityAction(.default) {
                positions?.activate(stack, hidesMedia: !shouldAutomaticallyLoadImages, context: context)
            }
            .accessibilityAction(named: UntranslatedL10n.guaMediaStackA11yNext) {
                positions?.page(stack, by: 1)
            }
            .accessibilityAction(named: UntranslatedL10n.guaMediaStackA11yPrevious) {
                positions?.page(stack, by: -1)
            }
            .accessibilityAction(named: UntranslatedL10n.guaMediaStackShowAll) {
                context?.send(viewAction: .mediaStackHeaderTapped(stackID: stack.id))
            }
    }
}

struct MediaStackRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel: TimelineViewModel = {
        let viewModel = TimelineViewModel.mock
        viewModel.state.mediaStackPositions.bringToFront(sending.members[1], of: sending) // Shows the failed card in front.
        return viewModel
    }()
    
    static let incomingPhotos = MediaStackRoomTimelineItem.mock(id: "incoming", members: (0..<4).map { .mockImage(index: $0, count: 4, batchID: "incoming") })
    
    static let outgoingMixed = MediaStackRoomTimelineItem.mock(id: "mixed", members: [.mockVideo(index: 0, count: 4, batchID: "mixed", isOutgoing: true)]
        + (1..<4).map { .mockImage(index: $0, count: 4, batchID: "mixed", isOutgoing: true) })
    
    static let twoPhotos = MediaStackRoomTimelineItem.mock(id: "two", members: (0..<2).map { .mockImage(index: $0, count: 2, batchID: "two") })
    
    static let captioned = MediaStackRoomTimelineItem.mock(id: "captioned", members: [
        .mockImage(index: 0, count: 3, batchID: "captioned", caption: "Beach day",
                   properties: .init(reactions: [AggregatedReaction(accountOwnerID: "@me:matrix.org",
                                                                    key: "❤️",
                                                                    senders: [ReactionSender(id: "@me:matrix.org", timestamp: .mock)])])),
        .mockImage(index: 1, count: 3, batchID: "captioned"),
        .mockImage(index: 2, count: 3, batchID: "captioned")
    ])
    
    static let sending = MediaStackRoomTimelineItem.mock(id: "sending", members: [
        .mockImage(index: 0, count: 4, batchID: "sending", isOutgoing: true),
        .mockImage(index: 1, count: 4, batchID: "sending", isOutgoing: true, properties: .init(deliveryStatus: .sendingFailed(.unknown(reason: nil)))),
        .mockImage(index: 2, count: 4, batchID: "sending", isOutgoing: true, properties: .init(deliveryStatus: .sending), uploadProgress: 0.4),
        .mockImage(index: 3, count: 4, batchID: "sending", isOutgoing: true, properties: .init(deliveryStatus: .sending))
    ])
    
    static var previews: some View {
        stacks([incomingPhotos, outgoingMixed, twoPhotos])
            .previewDisplayName("Stacks")
        
        stacks([captioned, sending])
            .previewDisplayName("Caption and sending")
        
        stacks([incomingPhotos])
            .environment(\.shouldAutomaticallyLoadImages, false)
            .previewDisplayName("Hidden media")
        
        stacks([incomingPhotos, captioned])
            .background(.compound.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark")
        
        stacks([captioned])
            .dynamicTypeSize(.accessibility2)
            .previewDisplayName("Accessibility XL")
        
        stacks([incomingPhotos, outgoingMixed])
            .environment(\.layoutDirection, .rightToLeft)
            .previewDisplayName("RTL")
    }
    
    private static func stacks(_ stacks: [MediaStackRoomTimelineItem]) -> some View {
        VStack(spacing: 16) {
            ForEach(stacks, id: \.id) { stack in
                MediaStackRoomTimelineView(timelineItem: stack)
            }
        }
        .padding(.vertical)
        .frame(maxHeight: .infinity, alignment: .top)
        .environmentObject(viewModel.context)
        .environment(\.timelineContext, viewModel.context)
        .previewLayout(.fixed(width: 390, height: CGFloat(stacks.count) * 420))
    }
}
