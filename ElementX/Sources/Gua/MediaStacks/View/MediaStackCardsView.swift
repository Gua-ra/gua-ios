//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The card each stack shows in front, kept per timeline so that a reused cell, the lifted copy in the
/// message menu and VoiceOver all agree.
@Observable
final class MediaStackPositions {
    private var frontIndexes: [TimelineItemIdentifier.UniqueID: Int] = [:]
    private var revealedStackIDs: Set<TimelineItemIdentifier.UniqueID> = []
    
    func frontIndex(of stack: MediaStackRoomTimelineItem) -> Int {
        min(frontIndexes[stack.id.uniqueID] ?? 0, stack.members.count - 1)
    }
    
    func setFrontIndex(_ index: Int, of stack: MediaStackRoomTimelineItem) {
        frontIndexes[stack.id.uniqueID] = index
    }
    
    func page(_ stack: MediaStackRoomTimelineItem, by step: Int) {
        let count = stack.members.count
        setFrontIndex(((frontIndex(of: stack) + step) % count + count) % count, of: stack)
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
    
    /// The physical direction of the reading order's leading edge.
    private var leadingSign: CGFloat {
        layoutDirection == .rightToLeft ? 1 : -1
    }
    
    /// Behind cards fan out toward the middle of the screen, away from the edge the stack is aligned to.
    private var fanSign: CGFloat {
        stack.isOutgoing ? leadingSign : -leadingSign
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
                                            dragProgress: min(abs(dragOffset) / Self.cardSize.width, 1),
                                            fanSign: fanSign))
                    .transition(.opacity)
                    .zIndex(Double(-card.slot))
            }
            
            if isHidden {
                MediaStackRevealButton()
            }
        }
        .frame(width: Self.frameSize.width, height: Self.frameSize.height)
        // The fan is placed in physical directions, picked from the reading order above. Each card keeps the reading order inside.
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.shouldAutomaticallyLoadImages, shouldAutomaticallyLoadImages || positions.isRevealed(stack))
        .contentShape(.rect)
        .gesture(MediaStackTapGesture(isEnabled: isInteractive) { handleTap() })
        .gesture(PanGestureRepresentable { handlePan($0) })
        .allowsHitTesting(isInteractive)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : nil, value: frontIndex)
    }
    
    private var visibleCards: [VisibleCard] {
        let count = stack.members.count
        return (0..<min(count, 3)).map { slot in
            let member = stack.members[((frontIndex + slot * revealStep) % count + count) % count]
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
            context?.send(viewAction: .mediaStackTapped(stackID: stack.id, index: frontIndex))
        }
    }
    
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isInteractive else { return }
        
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
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85).disabledDuringTests()) {
            dragOffset = (dragOffset < 0 ? -1 : 1) * Self.cardSize.width * 1.5
        } completion: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85).disabledDuringTests()) {
                positions.page(stack, by: step)
                dragOffset = 0
            }
        }
    }
    
    private func springBack() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85).disabledDuringTests()) {
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
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(x: fanSign * 6 * CGFloat(slot) + dragOffset, y: -4 * CGFloat(slot))
    }
    
    private var scale: CGFloat {
        switch slot {
        case 0: 1
        case 1: 0.96 + 0.04 * dragProgress
        default: 1 - 0.04 * CGFloat(slot)
        }
    }
    
    private var rotation: Double {
        if slot == 0 {
            Self.maximumDragRotation * Double(dragOffset / MediaStackCardsView.cardSize.width)
        } else {
            Double(fanSign) * Self.rotations[min(slot, 2)]
        }
    }
}

private struct MediaStackCard: View {
    @Environment(\.timelineContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    
    let member: MediaStackRoomTimelineItem.Member
    let isHidden: Bool
    
    private var isUnsent: Bool {
        member.item.properties.deliveryStatus == .sending
    }
    
    var body: some View {
        ContentScanningView(contentScannerService: context?.contentScannerService,
                            mediaSource: member.mediaSource,
                            thumbnailSource: member.thumbnailSource,
                            containerShowsFailure: false) {
            thumbnail
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
    private var thumbnail: some View {
        if isHidden {
            hiddenPlaceholder
        } else if let source = member.stillSource {
            LoadableImage(mediaSource: source,
                          mediaType: .timelineItem(uniqueID: member.id.uniqueID),
                          blurhash: member.blurhash,
                          size: member.thumbnailSize,
                          mediaProvider: context?.mediaProvider) { image in
                image.scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: MediaStackCardsView.cardSize.width, height: MediaStackCardsView.cardSize.height)
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
            CompoundIcon(\.playSolid)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: .circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            if let duration = member.duration {
                Text(MediaStackDuration.formatted(duration))
                    .font(.compound.bodyXSSemibold.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: .capsule)
                    .padding(8)
            }
        }
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

nonisolated extension MediaStackRoomTimelineItem.Member {
    var mediaSource: MediaSourceProxy {
        switch self {
        case .image(let item): item.content.imageInfo.source
        case .video(let item): item.content.videoInfo.source
        }
    }
    
    var thumbnailSource: MediaSourceProxy? {
        switch self {
        case .image(let item): item.content.thumbnailInfo?.source
        case .video(let item): item.content.thumbnailInfo?.source
        }
    }
    
    /// The image a card shows, the thumbnail first so that GIFs and WebPs stay still in a stack.
    var stillSource: MediaSourceProxy? {
        switch self {
        case .image(let item): item.content.thumbnailInfo?.source ?? item.content.imageInfo.source
        case .video(let item): item.content.thumbnailInfo?.source
        }
    }
    
    var thumbnailSize: CGSize? {
        switch self {
        case .image(let item): item.content.thumbnailInfo?.size ?? item.content.imageInfo.size
        case .video(let item): item.content.thumbnailInfo?.size
        }
    }
    
    var blurhash: String? {
        switch self {
        case .image(let item): item.content.blurhash
        case .video(let item): item.content.blurhash
        }
    }
    
    var duration: TimeInterval? {
        guard case let .video(item) = self else { return nil }
        return item.content.videoInfo.duration
    }
}
