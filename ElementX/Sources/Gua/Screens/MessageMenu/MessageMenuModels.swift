//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SFSafeSymbols
import SwiftUI

enum TimelineItemMenuPresentation: Equatable {
    case sheet
    case reactions(MessageMenuAnchor)
    case reactionsAndActions(MessageMenuAnchor)
    
    var anchor: MessageMenuAnchor? {
        switch self {
        case .sheet: nil
        case .reactions(let anchor), .reactionsAndActions(let anchor): anchor
        }
    }
    
    var showsActions: Bool {
        switch self {
        case .sheet, .reactionsAndActions: true
        case .reactions: false
        }
    }
    
    @MainActor
    static func floating(showsActions: Bool, over reader: WindowFrameReader) -> Self {
        guard let frame = reader.frame else { return .sheet }
        let anchor = MessageMenuAnchor(frame: frame, reader: reader)
        return showsActions ? .reactionsAndActions(anchor) : .reactions(anchor)
    }
}

/// The bubble can move while the menu is open, for example when the keyboard closes, so its frame is read again from the timeline.
@MainActor
final class MessageMenuAnchor: Equatable {
    private let initialFrame: CGRect
    private weak var reader: WindowFrameReader?
    
    init(frame: CGRect, reader: WindowFrameReader? = nil) {
        initialFrame = frame
        self.reader = reader
    }
    
    var frame: CGRect {
        reader?.frame ?? initialFrame
    }
    
    var isBubbleLifted: Bool {
        get { reader?.isLifted ?? false }
        set { reader?.isLifted = newValue }
    }
    
    nonisolated static func == (lhs: MessageMenuAnchor, rhs: MessageMenuAnchor) -> Bool {
        lhs === rhs
    }
}

extension TimelineViewState {
    func menuActionProvider(for item: RoomTimelineItemProtocol) -> TimelineItemMenuActionProvider {
        TimelineItemMenuActionProvider(timelineItem: item,
                                       canCurrentUserSendMessage: canCurrentUserSendMessage,
                                       canCurrentUserRedactSelf: canCurrentUserRedactSelf,
                                       canCurrentUserRedactOthers: canCurrentUserRedactOthers,
                                       canCurrentUserPin: canCurrentUserPin,
                                       pinnedEventIDs: pinnedEventIDs,
                                       isViewSourceEnabled: isViewSourceEnabled,
                                       areThreadsEnabled: areThreadsEnabled,
                                       timelineKind: timelineKind,
                                       emojiProvider: emojiProvider)
    }
}

struct TimelineItemTextSelectionInfo: Identifiable, Equatable {
    let id: TimelineItemIdentifier
    let text: String
}

enum MessageQuickReactions {
    /// Reaction keys are compared byte for byte across clients, so these must stay identical on every Gua platform.
    static let defaults: [TimelineItemMenuReaction] = [
        .init(key: "❤️", symbol: .heart),
        .init(key: "👍️", symbol: .handThumbsup),
        .init(key: "👎️", symbol: .handThumbsdown),
        .init(key: "😂", symbol: .faceSmiling),
        .init(key: "‼️", symbol: .exclamationmark2),
        .init(key: "❓\u{FE0F}", symbol: .questionmark)
    ]
    
    static let maximumCount = 10
}

struct MessageMenuSections: Equatable {
    enum Section { case primary, more, destructive }
    
    let primary: [TimelineItemMenuAction]
    let more: [TimelineItemMenuAction]
    let destructive: [TimelineItemMenuAction]
    
    init(actions: [TimelineItemMenuAction]) {
        func section(_ section: Section) -> [TimelineItemMenuAction] {
            let placed: [(action: TimelineItemMenuAction, order: Int)] = actions.compactMap { action in
                guard let placement = action.messageMenuPlacement, placement.section == section else { return nil }
                return (action, placement.order)
            }
            return placed.sorted { $0.order < $1.order }.map(\.action)
        }
        
        primary = section(.primary)
        more = section(.more)
        destructive = section(.destructive)
    }
}

extension TimelineItemMenuAction {
    var messageMenuPlacement: (section: MessageMenuSections.Section, order: Int)? {
        switch self {
        case .viewInRoomTimeline: (.primary, 0)
        case .reply: (.primary, 1)
        case .copy, .copyCaption: (.primary, 2)
        case .select: (.primary, 3)
        case .translate: (.primary, 4)
        case .edit, .editCaption, .addCaption, .editPoll: (.primary, 5)
        case .forward: (.primary, 6)
        case .downloadMedia, .saveMedia: (.primary, 7)
        case .replyInThread: (.more, 0)
        case .pin, .unpin: (.more, 1)
        case .copyPermalink: (.more, 2)
        case .endPoll: (.more, 3)
        case .removeCaption: (.more, 4)
        case .viewSource: (.more, 5)
        case .report: (.more, 6)
        case .redact: (.destructive, 0)
        case .react, .toggleReaction: nil
        }
    }
}

struct MessageMenuLayout: Equatable {
    let bubbleFrame: CGRect
    let reactionBarFrame: CGRect?
    let detailsFrame: CGRect?
    
    static let spacing: CGFloat = 8
    static let margin: CGFloat = 12
    static let minimumBubbleHeight: CGFloat = 44
    
    /// All frames use the container's coordinate space, measured from its left edge.
    init(sourceFrame: CGRect,
         alignsRight: Bool,
         container: CGRect,
         reactionBarSize: CGSize?,
         detailsSize: CGSize?) {
        let barSpace = reactionBarSize.map { $0.height + Self.spacing } ?? 0
        let minimumBubbleHeight = min(sourceFrame.height, Self.minimumBubbleHeight)
        let detailsHeight = detailsSize.map { min($0.height, max(0, container.height - barSpace - minimumBubbleHeight - Self.spacing)) }
        
        let top = container.minY + barSpace
        let bottom = container.maxY - (detailsHeight.map { $0 + Self.spacing } ?? 0)
        let height = max(0, min(sourceFrame.height, bottom - top))
        let y = min(max(sourceFrame.minY, top), bottom - height)
        let width = min(sourceFrame.width, container.width)
        let x = min(max(sourceFrame.minX, container.minX), container.maxX - width)
        let bubble = CGRect(x: x, y: y, width: width, height: height)
        
        func aligned(_ size: CGSize, y: CGFloat) -> CGRect {
            let width = min(size.width, container.width - 2 * Self.margin)
            let preferredX = alignsRight ? bubble.maxX - width : bubble.minX
            let x = min(max(preferredX, container.minX + Self.margin), container.maxX - Self.margin - width)
            return CGRect(x: x, y: y, width: width, height: size.height)
        }
        
        bubbleFrame = bubble
        reactionBarFrame = reactionBarSize.map { aligned($0, y: bubble.minY - Self.spacing - $0.height) }
        if let detailsSize, let detailsHeight {
            detailsFrame = aligned(CGSize(width: detailsSize.width, height: detailsHeight), y: bubble.maxY + Self.spacing)
        } else {
            detailsFrame = nil
        }
    }
}

struct MessageReactionSummaryRow: Equatable, Identifiable {
    let id: String
    let isOwnUser: Bool
    let keys: [String]
    
    static func rows(for reactions: [AggregatedReaction]) -> [MessageReactionSummaryRow] {
        var keys: [String: [String]] = [:]
        var earliest: [String: Date] = [:]
        var ownUserID: String?
        
        for reaction in reactions {
            for sender in reaction.senders {
                if keys[sender.id]?.contains(reaction.displayKey) != true {
                    keys[sender.id, default: []].append(reaction.displayKey)
                }
                earliest[sender.id] = min(earliest[sender.id] ?? sender.timestamp, sender.timestamp)
                if sender.id == reaction.accountOwnerID {
                    ownUserID = sender.id
                }
            }
        }
        
        let userIDs = keys.keys.sorted { lhs, rhs in
            if lhs == ownUserID || rhs == ownUserID {
                return lhs == ownUserID
            }
            if earliest[lhs] != earliest[rhs] {
                return earliest[lhs] ?? .distantFuture < earliest[rhs] ?? .distantFuture
            }
            return lhs < rhs
        }
        
        return userIDs.map { MessageReactionSummaryRow(id: $0, isOwnUser: $0 == ownUserID, keys: keys[$0] ?? []) }
    }
}

enum MessageSelectionText {
    static func make(body: String, formattedBody: AttributedString?, pillText: (PillType) -> String) -> String {
        guard let formattedBody, let attributedText = try? NSAttributedString(formattedBody, including: \.elementX) else {
            return body
        }
        
        var replacements: [(range: NSRange, text: String)] = []
        attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
            guard value != nil else { return }
            replacements.append((range, (value as? PillTextAttachment)?.pillData.map { pillText($0.type) } ?? ""))
        }
        
        let text = NSMutableString(string: attributedText.string)
        for replacement in replacements.reversed() {
            text.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
