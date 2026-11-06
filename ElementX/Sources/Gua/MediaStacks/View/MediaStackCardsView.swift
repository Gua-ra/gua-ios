//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

@Observable
final class MediaStackPositions {
    private var frontMemberIDs: [TimelineItemIdentifier.UniqueID: TimelineItemIdentifier.UniqueID] = [:]
    private var revealedStackIDs: Set<TimelineItemIdentifier.UniqueID> = []
    
    func frontIndex(of stack: MediaStackRoomTimelineItem) -> Int {
        let memberID = frontMemberIDs[stack.id.uniqueID]
        return stack.members.firstIndex { $0.id.uniqueID == memberID } ?? 0
    }
    
    func bringToFront(_ member: MediaStackRoomTimelineItem.Member, of stack: MediaStackRoomTimelineItem) {
        frontMemberIDs[stack.id.uniqueID] = member.id.uniqueID
    }
    
    func page(_ stack: MediaStackRoomTimelineItem, by step: Int) {
        bringToFront(stack.member(wrapping: frontIndex(of: stack) + step), of: stack)
    }
    
    func isRevealed(_ stack: MediaStackRoomTimelineItem) -> Bool {
        revealedStackIDs.contains(stack.id.uniqueID)
    }
    
    func reveal(_ stack: MediaStackRoomTimelineItem) {
        revealedStackIDs.insert(stack.id.uniqueID)
    }
}

struct MediaStackCardsView: View {
    static let cardSize = CGSize(width: 220, height: 275)
    static let frameSize = CGSize(width: cardSize.width + 12, height: cardSize.height + 8)
    
    private static let pageAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)
    
    @Environment(\.timelineContext) private var context
    @Environment(\.isMessageMenuPreview) private var isMessageMenuPreview
    @Environment(\.shouldAutomaticallyLoadImages) private var shouldAutomaticallyLoadImages
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    
    let stack: MediaStackRoomTimelineItem
    let positions: MediaStackPositions
    
    @State private var dragOffset: CGFloat = 0
    
    private var frontIndex: Int {
        positions.frontIndex(of: stack)
    }
    
    private var isInteractive: Bool {
        !isMessageMenuPreview && context?.viewState.messageSelection.isActive != true
    }
    
    private var isHidden: Bool {
        !shouldAutomaticallyLoadImages && !positions.isRevealed(stack)
    }
    
    private var leadingSign: CGFloat {
        layoutDirection == .rightToLeft ? 1 : -1
    }
    
    private var fanSign: CGFloat {
        stack.isOutgoing ? leadingSign : -leadingSign
    }
    
    /// The front card sits in the frame's outer bottom corner, so the fan fills the frame toward the screen centre and up.
    private var frontCardAlignment: Alignment {
        fanSign > 0 ? .bottomLeading : .bottomTrailing
    }
    
    /// Dragging toward the leading edge reveals the next card, toward the trailing edge the previous one.
    private var revealStep: Int {
        dragOffset * leadingSign < 0 ? -1 : 1
    }
    
    var body: some View {
        ZStack {
            ForEach(visibleCards) { card in
                MediaStackCard(member: card.member, isHidden: isHidden)
                    .environment(\.layoutDirection, layoutDirection)
                    .modifier(CardPlacement(slot: card.slot,
                                            dragOffset: card.slot == 0 && !reduceMotion ? dragOffset : 0,
                                            dragProgress: reduceMotion ? 0 : min(abs(dragOffset) / Self.cardSize.width, 1),
                                            fanSign: fanSign))
                    .transition(.opacity)
                    .zIndex(Double(-card.slot))
            }
            
            if isHidden {
                MediaStackRevealButton()
            }
        }
        .frame(width: Self.frameSize.width, height: Self.frameSize.height, alignment: frontCardAlignment)
        // The fan is placed in physical directions, picked from the reading order above. Each card keeps the reading order inside.
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.shouldAutomaticallyLoadImages, shouldAutomaticallyLoadImages || positions.isRevealed(stack))
        .contentShape(.rect)
        .gesture(MediaStackTapGesture(isEnabled: isInteractive) { handleTap() })
        .gesture(PanGestureRepresentable(isEnabled: isInteractive) { handlePan($0) })
        .allowsHitTesting(isInteractive)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : nil, value: frontIndex)
    }
    
    private var visibleCards: [VisibleCard] {
        (0..<min(stack.members.count, 3)).map { slot in
            let member = stack.member(wrapping: frontIndex + slot * revealStep)
            // With Reduce Motion the cards stay in place and only the front one cross-fades to the next.
            let id = reduceMotion && slot > 0 ? "slot-\(slot)" : member.id.uniqueID.value
            return VisibleCard(id: id, member: member, slot: slot)
        }
    }
    
    private func handleTap() {
        guard !isHidden else {
            positions.reveal(stack)
            return
        }
        
        let member = stack.members[frontIndex]
        if member.item.hasFailedToSend {
            context?.send(viewAction: .itemSendInfoTapped(itemID: member.id))
        } else {
            context?.send(viewAction: .mediaTapped(itemID: member.id))
        }
    }
    
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            dragOffset = gesture.translation(in: nil).x
        case .ended:
            let velocity = gesture.velocity(in: nil).x
            let passedThreshold = abs(dragOffset) > Self.cardSize.width * 0.3
            let isFlicked = abs(velocity) > 500 && velocity * dragOffset > 0
            if passedThreshold || isFlicked {
                commitPage()
            } else {
                springBack()
            }
        default:
            springBack()
        }
    }
    
    private func commitPage() {
        let step = revealStep
        UISelectionFeedbackGenerator().selectionChanged()
        
        guard !reduceMotion else {
            dragOffset = 0
            positions.page(stack, by: step)
            return
        }
        
        withAnimation(Self.pageAnimation.disabledDuringTests()) {
            dragOffset = (dragOffset < 0 ? -1 : 1) * Self.cardSize.width * 1.5
        } completion: {
            withAnimation(Self.pageAnimation.disabledDuringTests()) {
                positions.page(stack, by: step)
                dragOffset = 0
            }
        }
    }
    
    private func springBack() {
        withAnimation(Self.pageAnimation.disabledDuringTests()) {
            dragOffset = 0
        }
    }
}

private struct VisibleCard: Identifiable {
    let id: String
    let member: MediaStackRoomTimelineItem.Member
    let slot: Int
}

private struct CardPlacement: ViewModifier {
    private static let rotations: [Double] = [0, 3, -2]
    private static let maximumDragRotation: Double = 8
    
    let slot: Int
    let dragOffset: CGFloat
    let dragProgress: CGFloat
    let fanSign: CGFloat
    
    private var scale: CGFloat {
        switch slot {
        case 0: 1
        case 1: 0.96 + 0.04 * dragProgress
        default: 1 - 0.04 * CGFloat(slot)
        }
    }
    
    private var rotation: Double {
        if slot == 0 {
            Self.maximumDragRotation * Double(min(max(dragOffset / MediaStackCardsView.cardSize.width, -1), 1))
        } else {
            Double(fanSign) * Self.rotations[min(slot, 2)]
        }
    }
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(x: fanSign * 6 * CGFloat(slot) + dragOffset, y: -4 * CGFloat(slot))
    }
}

private struct MediaStackCard: View {
    @Environment(\.colorScheme) private var colorScheme
    
    let member: MediaStackRoomTimelineItem.Member
    let isHidden: Bool
    
    private var isUnsent: Bool {
        member.item.properties.deliveryStatus == .sending
    }
    
    var body: some View {
        MediaStackThumbnail(member: member, style: .card, isHidden: isHidden)
            .frame(width: MediaStackCardsView.cardSize.width, height: MediaStackCardsView.cardSize.height)
            .clipShape(.rect(cornerRadius: 18))
            .opacity(isUnsent ? 0.6 : 1)
            // Top-trailing, as the stack's send info sits in the bottom-trailing corner.
            .overlay(alignment: .topTrailing) { sendStateBadge }
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: 18).stroke(.compound.borderInteractiveSecondary, lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .light ? 0.12 : 0), radius: 3, y: 2)
    }
    
    @ViewBuilder
    private var sendStateBadge: some View {
        if member.item.hasFailedToSend {
            CompoundIcon(\.errorSolid, size: .small, relativeTo: .compound.bodyMD)
                .foregroundStyle(.compound.iconCriticalPrimary)
                .background(.compound.bgCanvasDefault, in: .circle)
                .padding(8)
        } else if isUnsent {
            MediaStackUploadRing(progress: member.uploadProgress)
                .padding(8)
        }
    }
}

struct MediaStackThumbnail: View {
    enum Style {
        case card
        case tile
    }
    
    @Environment(\.timelineContext) private var context
    @Environment(\.displayScale) private var displayScale
    
    let member: MediaStackRoomTimelineItem.Member
    let style: Style
    var isHidden = false
    
    private var requestedSize: CGSize {
        CGSize(width: MediaStackCardsView.cardSize.width * displayScale, height: MediaStackCardsView.cardSize.height * displayScale)
    }
    
    var body: some View {
        ContentScanningView(contentScannerService: context?.contentScannerService,
                            mediaSource: member.mediaSource,
                            thumbnailSource: member.thumbnailSource,
                            containerShowsFailure: false) {
            Color.clear
                .overlay { image }
                .clipped()
                .overlay {
                    if member.isVideo {
                        videoOverlay
                    }
                }
        } scanningContent: {
            placeholder.overlay { ProgressView() }
        } unsafeContent: { failure in
            ContentScanningFailureView(failure: failure)
        }
    }
    
    @ViewBuilder
    private var image: some View {
        if isHidden {
            hiddenPlaceholder
        } else if let source = member.stillSource {
            LoadableImage(mediaSource: source,
                          mediaType: .timelineItem(uniqueID: member.id.uniqueID),
                          blurhash: member.blurhash,
                          size: requestedSize,
                          mediaProvider: context?.mediaProvider) { image in
                image.scaledToFill()
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }
    
    private var placeholder: some View {
        Color.compound.bgSubtleSecondary
    }
    
    private var hiddenPlaceholder: some View {
        ZStack {
            if let blurhash = member.blurhash, let image = UIImage(blurHash: blurhash, size: .init(width: 10, height: 10)) {
                Image(uiImage: image).resizable()
            } else {
                placeholder
            }
            
            Color.black.opacity(0.6)
        }
    }
    
    private var videoOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            CompoundIcon(\.playSolid, size: style == .card ? .medium : .small, relativeTo: style == .card ? .compound.bodyLG : .compound.bodyMD)
                .foregroundStyle(.white)
                .frame(width: style == .card ? 44 : 32, height: style == .card ? 44 : 32)
                .background(.black.opacity(0.45), in: .circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            if let duration = member.duration {
                Text(MediaStackDuration.formatted(duration))
                    .font(.compound.bodyXSSemibold.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: .capsule)
                    .padding(style == .card ? 8 : 6)
            }
        }
    }
}

private struct MediaStackUploadRing: View {
    /// `nil` while the item waits for the ones before it.
    let progress: Double?
    
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.4), lineWidth: 2.5)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: .init(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct MediaStackRevealButton: View {
    var body: some View {
        Text(L10n.actionShow)
            .font(.compound.bodyLGSemibold)
            .foregroundStyle(.compound.textOnSolidPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .overlay {
                Capsule().stroke(lineWidth: 1).foregroundStyle(.compound.borderInteractiveSecondary)
            }
            .environment(\.colorScheme, .light)
            .allowsHitTesting(false)
    }
}

/// A single tap that waits for the bubble's double tap to fail, so that a double tap reacts instead of opening the media.
struct MediaStackTapGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let action: () -> Void
    
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        .init()
    }
    
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let gesture = UITapGestureRecognizer()
        gesture.delegate = context.coordinator
        gesture.isEnabled = isEnabled
        return gesture
    }
    
    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }
    
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended {
            action()
        }
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            (otherGestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
        }
    }
}

nonisolated enum MediaStackDuration {
    static func formatted(_ duration: TimeInterval) -> String {
        let duration = Duration.seconds(duration)
        return duration.formatted(.time(pattern: duration >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond))
    }
}

extension MediaStackRoomTimelineItem {
    func member(wrapping index: Int) -> Member {
        members[(index % members.count + members.count) % members.count]
    }
}

private extension MediaStackRoomTimelineItem.Member {
    var stillSource: MediaSourceProxy? {
        let source = switch self {
        case .image(let item): item.content.thumbnailInfo?.source ?? item.content.imageInfo.source
        case .video(let item): item.content.thumbnailInfo?.source
        }
        // Without a MIME type the loader decodes a single frame, so an animated GIF stays still.
        return source.map { MediaSourceProxy(source: $0.underlyingSource, mimeType: nil) }
    }
}
