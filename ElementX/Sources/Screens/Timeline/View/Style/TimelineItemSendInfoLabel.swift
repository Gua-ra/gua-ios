//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

extension View {
    /// Adds the send info (timestamp along indicators for edits and delivery/encryption issues) for the given timeline item to this view.
    func timelineItemSendInfo(timelineItem: EventBasedTimelineItemProtocol,
                              adjustedDeliveryStatus: TimelineItemDeliveryStatus?,
                              hasContentScanningFailure: Bool = false,
                              context: TimelineViewModel.Context) -> some View {
        modifier(TimelineItemSendInfoModifier(sendInfo: .init(timelineItem: timelineItem,
                                                              adjustedDeliveryStatus: adjustedDeliveryStatus,
                                                              hasContentScanningFailure: hasContentScanningFailure),
                                              // A gallery announces this when entering it instead, a stack as part of its value.
                                              isAccessibilityHidden: timelineItem is GalleryRoomTimelineItem || timelineItem is MediaStackRoomTimelineItem,
                                              context: context))
    }
}

/// Adds the send info to a view with the correct layout.
private struct TimelineItemSendInfoModifier: ViewModifier {
    let sendInfo: TimelineItemSendInfo
    let isAccessibilityHidden: Bool
    let context: TimelineViewModel.Context
    
    var layout: AnyLayout {
        switch sendInfo.layoutType {
        case .horizontal(let spacing):
            AnyLayout(HStackLayout(alignment: .bottom, spacing: spacing))
        case .vertical(let spacing):
            AnyLayout(GridLayout(alignment: .leading, verticalSpacing: spacing))
        case .overlay, .hidden:
            AnyLayout(ZStackLayout(alignment: .bottomTrailing))
        }
    }
    
    func body(content: Content) -> some View {
        layout {
            content
            
            TimelineItemSendInfoLabel(sendInfo: sendInfo)
                .accessibilityHidden(isAccessibilityHidden)
                .contentShape(.rect)
                // Only tappable labels get the identifier, plain timestamps would be ambiguous matches.
                .accessibilityIdentifier(sendInfo.status != nil ? A11yIdentifiers.roomScreen.sendInfo : "")
                // Tap gesture to avoid the message being detected as a button by VoiceOver
                // (and the action shows a description that is already read to the user).
                .onTapGesture {
                    guard sendInfo.status != nil else { return }
                    context.send(viewAction: .itemSendInfoTapped(itemID: sendInfo.itemID))
                }
        }
    }
}

/// The label shown for a timeline item with info about it's timestamp and various other indicators.
private struct TimelineItemSendInfoLabel: View {
    let sendInfo: TimelineItemSendInfo
    
    var statusIcon: KeyPath<CompoundIcons, Image>? {
        switch sendInfo.status {
        case .sendingFailed: \.errorSolid
        case .encryptionAuthenticity(let authenticity): authenticity.icon
        case .encryptionForwarder: \.info
        case .none: nil
        }
    }
    
    var statusIconAccessibilityLabel: String? {
        switch sendInfo.status {
        case .sendingFailed: L10n.commonSendingFailed
        case .encryptionAuthenticity(let authenticity): authenticity.message
        case .encryptionForwarder(let forwarder): forwarder.message
        case .none: nil
        }
    }
    
    var body: some View {
        switch sendInfo.layoutType {
        case .overlay(capsuleStyle: true):
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.compound.bgSubtleSecondary)
                .cornerRadius(10)
                .padding(.trailing, sendInfo.capsuleInset)
                .padding(.bottom, sendInfo.capsuleInset)
        case .horizontal, .overlay(capsuleStyle: false):
            content
                .padding(.bottom, -4)
        case .vertical:
            GridRow {
                content
                    .gridColumnAlignment(.trailing)
            }
        case .hidden:
            EmptyView()
        }
    }
    
    var content: some View {
        HStack(spacing: 4) {
            Text(sendInfo.localizedString)
            
            if let statusIcon {
                CompoundIcon(statusIcon, size: .xSmall, relativeTo: .compound.bodyXS)
                    .accessibilityLabel(statusIconAccessibilityLabel ?? "")
                    .accessibilityHidden(statusIconAccessibilityLabel == nil)
            }
        }
        .font(.compound.bodyXS)
        .foregroundStyle(sendInfo.foregroundStyle)
    }
}

/// All the data needed to render a timeline item's send info label.
private struct TimelineItemSendInfo {
    enum Status {
        case sendingFailed
        case encryptionAuthenticity(EncryptionAuthenticity)
        case encryptionForwarder(TimelineItemKeyForwarder)
    }
    
    /// Describes how the content and the send info should be arranged inside a bubble
    enum LayoutType {
        case horizontal(spacing: CGFloat = 4)
        case vertical(spacing: CGFloat = 4)
        case overlay(capsuleStyle: Bool)
        case hidden
    }
    
    let itemID: TimelineItemIdentifier
    let localizedString: String
    var status: Status?
    let layoutType: LayoutType
    var capsuleInset: CGFloat = 4
    
    var foregroundStyle: Color {
        switch status {
        case .sendingFailed:
            .compound.textCriticalPrimary
        case .encryptionAuthenticity(let authenticity):
            authenticity.foregroundStyle
        case .encryptionForwarder:
            .compound.textSecondary
        case .none:
            .compound.textSecondary
        }
    }
}

private extension TimelineItemSendInfo {
    init(timelineItem: EventBasedTimelineItemProtocol,
         adjustedDeliveryStatus: TimelineItemDeliveryStatus?,
         hasContentScanningFailure: Bool = false) {
        itemID = timelineItem.id
        localizedString = timelineItem.localizedSendInfo
        
        status = if case .sendingFailed = adjustedDeliveryStatus {
            .sendingFailed
        } else if let authenticity = timelineItem.properties.encryptionAuthenticity {
            // GUA FORK: a shield about the sender's own setup says nothing useful on your own
            // message. It is not a risk you can act on, it is not something you did wrong, and
            // sitting in the delivery-status slot it reads as "this failed to send".
            timelineItem.isOutgoing && authenticity.describesOwnSetup ? nil : .encryptionAuthenticity(authenticity)
        } else if let forwarder = timelineItem.properties.encryptionForwarder {
            .encryptionForwarder(forwarder)
        } else {
            nil
        }
        
        layoutType = if hasContentScanningFailure {
            // The content scanner failure placeholder replaces the media,
            // so the send info is laid out like it is for a text message.
            timelineItem.hasMediaCaption ? .overlay(capsuleStyle: false) : .horizontal()
        } else {
            switch timelineItem {
            case is TextBasedRoomTimelineItem:
                .overlay(capsuleStyle: false)
            case let liveLocationTimelineItem as LiveLocationRoomTimelineItem:
                liveLocationTimelineItem.layout
            case let message as EventBasedMessageTimelineItemProtocol:
                switch message {
                case is ImageRoomTimelineItem, is VideoRoomTimelineItem:
                    .overlay(capsuleStyle: !message.hasMediaCaption)
                case is MediaStackRoomTimelineItem:
                    // The stack has no bubble of its own, even under a caption.
                    .overlay(capsuleStyle: true)
                case is GalleryRoomTimelineItem:
                    // Without a caption, append the send info below the grid rather than overlaying
                    // a capsule on top of the media.
                    message.hasMediaCaption ? .overlay(capsuleStyle: false) : .vertical()
                case is AudioRoomTimelineItem, is FileRoomTimelineItem:
                    // swiftlint:disable:next void_function_in_ternary
                    message.hasMediaCaption ? .overlay(capsuleStyle: false) : .horizontal(spacing: 0) // No spacing as the content already contains it.
                case let locationTimelineItem as LocationRoomTimelineItem:
                    .overlay(capsuleStyle: locationTimelineItem.content.geoURI != nil)
                default:
                    .horizontal()
                }
            case is StickerRoomTimelineItem:
                .overlay(capsuleStyle: true)
            case is PollRoomTimelineItem:
                .vertical(spacing: 16)
            default:
                .horizontal()
            }
        }
        
        // Without a caption the capsule sits on the cards, clear of their rounded corners.
        if timelineItem is MediaStackRoomTimelineItem, !timelineItem.hasMediaCaption {
            capsuleInset = 8
        }
    }
}

private extension LiveLocationRoomTimelineItem {
    var layout: TimelineItemSendInfo.LayoutType {
        if content.isLive, isOutgoing {
            .hidden
        } else {
            .overlay(capsuleStyle: true)
        }
    }
}

private extension EncryptionAuthenticity {
    var foregroundStyle: SwiftUI.Color {
        // GUA FORK: the SDK's red is advisory, and this label shares its slot and colour with
        // "failed to send". Only the states that genuinely mean "this may not be who you think"
        // are allowed to borrow the critical colour.
        guard isAlarming else { return .compound.textSecondary }
        
        return switch color {
        case .red: .compound.textCriticalPrimary
        case .gray: .compound.textSecondary
        }
    }
}

private extension TimelineItemKeyForwarder {
    static var test: TimelineItemKeyForwarder {
        TimelineItemKeyForwarder(id: "@alice:matrix.org", displayName: "alice")
    }
}

// MARK: - Previews

struct TimelineItemSendInfoLabel_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 16) {
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .sendingFailed,
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionAuthenticity(.unsignedDevice(color: .red)),
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionAuthenticity(.notGuaranteed(color: .gray)),
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionAuthenticity(.sentInClear(color: .red)),
                                                      layoutType: .horizontal()))
            TimelineItemSendInfoLabel(sendInfo: .init(itemID: .randomEvent,
                                                      localizedString: "09:47 AM",
                                                      status: .encryptionForwarder(.test),
                                                      layoutType: .horizontal()))
        }
    }
}
