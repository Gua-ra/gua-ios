//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SFSafeSymbols
import SwiftUI

/// How the menu for a timeline item is shown.
enum TimelineItemMenuPresentation: Equatable {
    /// The full action sheet, used by VoiceOver and the media browser.
    case sheet
    /// Quick reactions above the message bubble, opened by a double tap.
    case reactions(sourceFrame: CGRect)
    /// Quick reactions above the message bubble and actions below it, opened by a long press.
    case reactionsAndActions(sourceFrame: CGRect)

    /// The message bubble in window coordinates.
    var sourceFrame: CGRect? {
        switch self {
        case .sheet: nil
        case .reactions(let sourceFrame), .reactionsAndActions(let sourceFrame): sourceFrame
        }
    }

    var showsActions: Bool {
        switch self {
        case .sheet, .reactionsAndActions: true
        case .reactions: false
        }
    }
}

struct TimelineItemTextSelectionInfo: Identifiable, Equatable {
    let id: TimelineItemIdentifier
    let text: String
}

enum MessageQuickReactions {
    /// The reactions offered first on every message. Reaction keys are compared byte for byte
    /// across clients, so these must stay identical on every Gua platform.
    static let defaults: [TimelineItemMenuReaction] = [
        .init(key: "❤️", symbol: .heart),
        .init(key: "👍️", symbol: .handThumbsup),
        .init(key: "👎️", symbol: .handThumbsdown),
        .init(key: "😂", symbol: .faceSmiling),
        .init(key: "‼️", symbol: .exclamationmark2),
        .init(key: "❓", symbol: .questionmark)
    ]

    static let maximumCount = 10
}

/// Splits the menu actions into the rows shown under a message bubble.
struct MessageMenuSections: Equatable {
    enum Section { case primary, more, destructive }
    
    /// Shown directly under the bubble.
    let primary: [TimelineItemMenuAction]
    /// Shown after tapping More.
    let more: [TimelineItemMenuAction]
    /// Shown last, below a separator.
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
        case .edit, .editCaption, .addCaption, .editPoll: (.primary, 4)
        case .forward: (.primary, 5)
        case .share: (.primary, 6)
        case .save: (.primary, 7)
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

/// Places the message bubble, the reaction bar and the action list on screen.
struct MessageMenuLayout: Equatable {
    /// The bubble's frame, moved to fit and clipped if taller than the space left.
    let bubbleFrame: CGRect
    let reactionBarFrame: CGRect?
    let actionsFrame: CGRect?

    static let spacing: CGFloat = 8
    static let margin: CGFloat = 12

    /// All frames share the container's coordinate space.
    init(sourceFrame: CGRect,
         isOutgoing: Bool,
         container: CGRect,
         reactionBarSize: CGSize?,
         actionsSize: CGSize?) {
        let top = container.minY + (reactionBarSize.map { $0.height + Self.spacing } ?? 0)
        let bottom = container.maxY - (actionsSize.map { $0.height + Self.spacing } ?? 0)
        let height = max(0, min(sourceFrame.height, bottom - top))
        let y = min(max(sourceFrame.minY, top), bottom - height)
        let bubble = CGRect(x: sourceFrame.minX, y: y, width: sourceFrame.width, height: height)
        
        func aligned(_ size: CGSize, y: CGFloat) -> CGRect {
            let width = min(size.width, container.width - 2 * Self.margin)
            let preferredX = isOutgoing ? sourceFrame.maxX - width : sourceFrame.minX
            let x = min(max(preferredX, container.minX + Self.margin), container.maxX - Self.margin - width)
            return CGRect(x: x, y: y, width: width, height: size.height)
        }
        
        bubbleFrame = bubble
        reactionBarFrame = reactionBarSize.map { aligned($0, y: bubble.minY - Self.spacing - $0.height) }
        actionsFrame = actionsSize.map { aligned($0, y: bubble.maxY + Self.spacing) }
    }
}
