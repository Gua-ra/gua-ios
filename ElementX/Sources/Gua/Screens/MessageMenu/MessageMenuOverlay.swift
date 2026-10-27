//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The message lifted above a dimmed timeline, with quick reactions above it and, after a long press, its actions below it.
struct MessageMenuOverlay: View {
    @EnvironmentObject private var context: TimelineViewModel.Context

    let item: EventBasedTimelineItemProtocol
    let actions: TimelineItemMenuActions
    let presentation: TimelineItemMenuPresentation
    let groupStyle: TimelineGroupStyle
    /// Removes the overlay without animation. The overlay animates out before calling it.
    let dismiss: () -> Void

    @State private var isVisible: Bool
    @State private var isShowingMore: Bool
    @State private var actionsHeight: CGFloat = 0

    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

    init(item: EventBasedTimelineItemProtocol,
         actions: TimelineItemMenuActions,
         presentation: TimelineItemMenuPresentation,
         groupStyle: TimelineGroupStyle,
         animatesIn: Bool = true,
         isShowingMore: Bool = false,
         dismiss: @escaping () -> Void) {
        self.item = item
        self.actions = actions
        self.presentation = presentation
        self.groupStyle = groupStyle
        self.dismiss = dismiss
        _isVisible = State(initialValue: !animatesIn)
        _isShowingMore = State(initialValue: isShowingMore)
    }

    private var sections: MessageMenuSections {
        MessageMenuSections(actions: actions.actions + actions.secondaryActions)
    }

    private var showsActions: Bool {
        presentation.showsActions && !(sections.primary.isEmpty && sections.more.isEmpty && sections.destructive.isEmpty)
    }

    var body: some View {
        ZStack {
            backdrop

            GeometryReader { geometry in
                let container = geometry.frame(in: .global)
                let sourceFrame = (presentation.sourceFrame ?? .zero).offsetBy(dx: -container.minX, dy: -container.minY)
                let layout = MessageMenuLayout(sourceFrame: sourceFrame,
                                               isOutgoing: item.isOutgoing,
                                               container: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 0, dy: MessageMenuLayout.spacing),
                                               reactionBarSize: actions.reactions.isEmpty ? nil : reactionBarSize(in: geometry.size),
                                               actionsSize: showsActions ? CGSize(width: Self.actionsWidth, height: actionsHeight) : nil)

                ZStack(alignment: .topLeading) {
                    bubble(width: sourceFrame.width)
                        .frame(width: layout.bubbleFrame.width, height: layout.bubbleFrame.height, alignment: .top)
                        .clipped()
                        .shadow(color: .black.opacity(isVisible ? 0.15 : 0), radius: 12, y: 4)
                        .offset(x: layout.bubbleFrame.minX, y: isVisible ? layout.bubbleFrame.minY : sourceFrame.minY)

                    if let frame = layout.reactionBarFrame {
                        reactionBar
                            .frame(width: frame.width, height: frame.height)
                            .scaleEffect(isVisible ? 1 : 0.5, anchor: item.isOutgoing ? .bottomTrailing : .bottomLeading)
                            .opacity(isVisible ? 1 : 0)
                            .offset(x: frame.minX, y: frame.minY)
                    }

                    if let frame = layout.actionsFrame {
                        actionList
                            .frame(width: frame.width)
                            .readHeight($actionsHeight)
                            .scaleEffect(isVisible ? 1 : 0.5, anchor: item.isOutgoing ? .topTrailing : .topLeading)
                            .opacity(isVisible && actionsHeight > 0 ? 1 : 0)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .onAppear {
            guard !isVisible else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8).disabledDuringTests()) {
                isVisible = true
            }
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.15))
            .opacity(isVisible ? 1 : 0)
            .ignoresSafeArea()
            .onTapGesture { close() }
            .accessibilityHidden(true)
    }

    // MARK: - Bubble

    private func bubble(width: CGFloat) -> some View {
        RoomTimelineItemView(viewState: RoomTimelineItemViewState(item: item, groupStyle: groupStyle))
            .environment(\.isMessageMenuPreview, true)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
    }

    // MARK: - Reactions

    private static let reactionSize: CGFloat = 44
    private static let reactionSpacing: CGFloat = 2
    private static let reactionBarPadding: CGFloat = 6

    private func reactionBarSize(in containerSize: CGSize) -> CGSize {
        let count = CGFloat(actions.reactions.count)
        let reactionsWidth = count * Self.reactionSize + (count - 1) * Self.reactionSpacing + 2 * Self.reactionBarPadding
        let width = reactionsWidth + Self.reactionSize + Self.reactionBarPadding
        return CGSize(width: min(width, containerSize.width - 2 * MessageMenuLayout.margin),
                      height: Self.reactionSize + 2 * Self.reactionBarPadding)
    }

    private var reactionBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: Self.reactionSpacing) {
                    ForEach(actions.reactions, id: \.key) { reaction in
                        reactionButton(for: reaction.key)
                    }
                }
                .padding(.horizontal, Self.reactionBarPadding)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            Button {
                close {
                    context.send(viewAction: .displayEmojiPicker(itemID: item.id))
                }
            } label: {
                CompoundIcon(\.reactionAdd, size: .medium, relativeTo: .compound.headingLG)
                    .foregroundStyle(.compound.iconSecondary)
                    .frame(width: Self.reactionSize, height: Self.reactionSize)
            }
            .padding(.trailing, Self.reactionBarPadding)
            .accessibilityLabel(L10n.actionReact)
        }
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private func reactionButton(for key: String) -> some View {
        let hasReacted = item.properties.reactions.contains { $0.key == key && $0.isHighlighted }

        return Button {
            feedbackGenerator.impactOccurred()
            context.send(viewAction: .toggleReaction(key: key, itemID: item.id))
            close()
        } label: {
            Text(key)
                .font(.system(size: 28))
                .frame(width: Self.reactionSize, height: Self.reactionSize)
                .background(Circle().fill(hasReacted ? Color.compound.bgSubtlePrimary : .clear))
                .overlay(Circle().strokeBorder(hasReacted ? Color.compound.borderInteractivePrimary : .clear))
        }
        .accessibilityLabel(hasReacted ? L10n.a11yRemoveReaction(key) : L10n.a11yAddReaction(key))
    }

    // MARK: - Actions

    private static let actionsWidth: CGFloat = 250

    private var actionList: some View {
        VStack(spacing: 0) {
            if isShowingMore {
                Button {
                    withAnimation(.easeInOut(duration: 0.2).disabledDuringTests()) { isShowingMore = false }
                } label: {
                    Label(UntranslatedL10n.guaActionMore, icon: \.chevronLeft)
                        .font(.compound.bodyLGSemibold)
                }
                .buttonStyle(MessageMenuButtonStyle())

                Divider()

                ForEach(sections.more, id: \.self) { actionButton(for: $0) }
            } else {
                ForEach(sections.primary, id: \.self) { actionButton(for: $0) }

                if !sections.more.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2).disabledDuringTests()) { isShowingMore = true }
                    } label: {
                        Label(UntranslatedL10n.guaActionMore, icon: \.overflowHorizontal)
                    }
                    .buttonStyle(MessageMenuButtonStyle(showsChevron: true))
                }

                if !sections.destructive.isEmpty {
                    Divider()
                        .frame(height: 6)
                        .overlay(Color.compound.bgSubtlePrimary.opacity(0.6))

                    ForEach(sections.destructive, id: \.self) { actionButton(for: $0) }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private func actionButton(for action: TimelineItemMenuAction) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            close {
                context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: action))
            }
        } label: {
            action.label
        }
        .buttonStyle(MessageMenuButtonStyle())
    }

    // MARK: - Dismissal

    private func close(then action: (() -> Void)? = nil) {
        withAnimation(.easeOut(duration: 0.18).disabledDuringTests()) {
            isVisible = false
        }

        Task {
            if !ProcessInfo.isRunningTests {
                try? await Task.sleep(for: .seconds(0.18))
            }
            dismiss()

            guard let action else { return }
            // A sheet presented while the overlay is still being removed would be refused.
            try? await Task.sleep(for: .seconds(0.1))
            action()
        }
    }
}

private struct MessageMenuButtonStyle: ButtonStyle {
    var showsChevron = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .labelStyle(MessageMenuLabelStyle())

            if showsChevron {
                CompoundIcon(\.chevronRight, size: .small, relativeTo: .compound.bodyLG)
                    .foregroundStyle(.compound.iconTertiary)
            }
        }
        .font(.compound.bodyLG)
        .foregroundStyle(configuration.role == .destructive ? .compound.textCriticalPrimary : .compound.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(configuration.isPressed ? Color.compound.bgSubtlePrimary : .clear)
    }
}

private struct MessageMenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .frame(width: 24, height: 24)
            configuration.title
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Previews

struct MessageMenuOverlay_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock

    static let incomingItem = TextRoomTimelineItem(id: .randomEvent,
                                                   timestamp: .mock,
                                                   isOutgoing: false,
                                                   isEditable: false,
                                                   canBeRepliedTo: true,
                                                   sender: .init(id: "@camila:gua", displayName: "Camila Moraes"),
                                                   content: .init(body: "Me mudei pra Floripa ano passado, tô morando de frente pro mar agora 🌅"))

    static let outgoingItem = TextRoomTimelineItem(id: .randomEvent,
                                                   timestamp: .mock,
                                                   isOutgoing: true,
                                                   isEditable: true,
                                                   canBeRepliedTo: true,
                                                   sender: .init(id: "@voce:gua", displayName: "Você"),
                                                   content: .init(body: "Que paz nesse lugar 😍"))

    static var previews: some View {
        overlay(item: incomingItem, presentation: .reactions(sourceFrame: CGRect(x: 16, y: 320, width: 300, height: 82)))
            .previewDisplayName("Double tap")

        overlay(item: incomingItem, presentation: .reactionsAndActions(sourceFrame: CGRect(x: 16, y: 240, width: 300, height: 82)))
            .previewDisplayName("Long press")

        overlay(item: outgoingItem, presentation: .reactionsAndActions(sourceFrame: CGRect(x: 120, y: 620, width: 240, height: 58)))
            .previewDisplayName("Long press near the bottom")

        overlay(item: incomingItem,
                presentation: .reactionsAndActions(sourceFrame: CGRect(x: 16, y: 240, width: 300, height: 82)),
                isShowingMore: true)
            .previewDisplayName("More")
    }

    static func overlay(item: TextRoomTimelineItem,
                        presentation: TimelineItemMenuPresentation,
                        isShowingMore: Bool = false) -> some View {
        let actions = TimelineItemMenuActionProvider(timelineItem: item,
                                                     canCurrentUserSendMessage: true,
                                                     canCurrentUserRedactSelf: true,
                                                     canCurrentUserRedactOthers: false,
                                                     canCurrentUserPin: true,
                                                     pinnedEventIDs: [],
                                                     isDM: true,
                                                     isViewSourceEnabled: false,
                                                     areThreadsEnabled: false,
                                                     timelineKind: .live,
                                                     emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings))
            .makeActions()

        return ZStack {
            Color.compound.bgCanvasDefault.ignoresSafeArea()

            if let actions {
                MessageMenuOverlay(item: item,
                                   actions: actions,
                                   presentation: presentation,
                                   groupStyle: .single,
                                   animatesIn: false,
                                   isShowingMore: isShowingMore) { }
            }
        }
        .environmentObject(viewModel.context)
        .environment(\.timelineContext, viewModel.context)
    }
}
