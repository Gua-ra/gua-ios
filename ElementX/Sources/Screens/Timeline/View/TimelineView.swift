//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import WysiwygComposer

struct TimelineView: View {
    @ObservedObject var timelineContext: TimelineViewModel.Context
    @State private var dragOver = false
    /// The message menu drawn over the timeline. Mirrors `actionMenuInfo` so it can be shown without the cover's slide animation.
    @State private var messageMenuInfo: TimelineItemActionMenuInfo?
    
    var body: some View {
        TimelineViewRepresentable()
            .id(timelineContext.viewState.roomID)
            // It is tempting to inject these environment values last to avoid also injecting them into the sheets,
            // and that approach works great on iOS. But it doesn't work on macOS (as of 15.5) where the app goes 💥
            .environmentObject(timelineContext)
            .environment(\.timelineContext, timelineContext)
            .environment(\.focussedEventID, timelineContext.viewState.timelineState.focussedEvent?.eventID)
            .alert(item: $timelineContext.alertInfo)
            .sheet(item: $timelineContext.manageMemberViewModel) {
                ManageRoomMemberSheetView(context: $0.context)
            }
            .sheet(item: $timelineContext.debugInfo) { TimelineItemDebugView(info: $0) }
            .sheet(item: actionMenuSheetInfo) { info in
                if let actions = menuActions(for: info.item) {
                    TimelineItemMenu(item: info.item, actions: actions)
                        .environmentObject(timelineContext)
                }
            }
            .fullScreenCover(item: $messageMenuInfo) { info in
                if let actions = menuActions(for: info.item) {
                    MessageMenuOverlay(item: info.item,
                                       actions: actions,
                                       presentation: info.presentation,
                                       groupStyle: timelineContext.viewState.timelineState.itemsDictionary[info.item.id.uniqueID]?.groupStyle ?? .single) {
                        timelineContext.actionMenuInfo = nil
                    }
                    .environmentObject(timelineContext)
                    .environment(\.timelineContext, timelineContext)
                    .presentationBackground(.clear)
                }
            }
            .onChange(of: timelineContext.actionMenuInfo) { _, info in
                let menuInfo = info?.presentation.sourceFrame == nil ? nil : info
                guard menuInfo != messageMenuInfo else { return }
                withTransaction(\.disablesAnimations, true) {
                    messageMenuInfo = menuInfo
                }
            }
            .sheet(item: $timelineContext.textSelectionInfo) { info in
                MessageTextSelectionSheet(info: info)
            }
            .sheet(item: $timelineContext.reactionSummaryInfo) {
                ReactionsSummaryView(reactions: $0.reactions,
                                     members: timelineContext.viewState.members,
                                     mediaProvider: timelineContext.mediaProvider,
                                     selectedReactionKey: $0.selectedKey)
                    .edgesIgnoringSafeArea([.bottom])
            }
            .sheet(item: $timelineContext.readReceiptsSummaryInfo) {
                ReadReceiptsSummaryView(orderedReadReceipts: $0.orderedReceipts)
                    .environmentObject(timelineContext)
            }
            .onDrop(of: ["public.item", "public.file-url"], isTargeted: $dragOver) { providers -> Bool in
                let supportedProviders = providers.filter(\.isSupportedForPasteOrDrop)
                
                guard !supportedProviders.isEmpty else {
                    return false
                }
                
                timelineContext.send(viewAction: .handlePasteOrDrop(providers: supportedProviders))
                return true
            }
    }
    
    private var actionMenuSheetInfo: Binding<TimelineItemActionMenuInfo?> {
        Binding {
            timelineContext.actionMenuInfo?.presentation == .sheet ? timelineContext.actionMenuInfo : nil
        } set: { info in
            timelineContext.actionMenuInfo = info
        }
    }
    
    private func menuActions(for item: EventBasedTimelineItemProtocol) -> TimelineItemMenuActions? {
        TimelineItemMenuActionProvider(timelineItem: item,
                                       canCurrentUserSendMessage: timelineContext.viewState.canCurrentUserSendMessage,
                                       canCurrentUserRedactSelf: timelineContext.viewState.canCurrentUserRedactSelf,
                                       canCurrentUserRedactOthers: timelineContext.viewState.canCurrentUserRedactOthers,
                                       canCurrentUserPin: timelineContext.viewState.canCurrentUserPin,
                                       pinnedEventIDs: timelineContext.viewState.pinnedEventIDs,
                                       isDM: timelineContext.viewState.isDirectOneToOneRoom,
                                       isViewSourceEnabled: timelineContext.viewState.isViewSourceEnabled,
                                       areThreadsEnabled: timelineContext.viewState.areThreadsEnabled,
                                       timelineKind: timelineContext.viewState.timelineKind,
                                       emojiProvider: timelineContext.viewState.emojiProvider)
            .makeActions()
    }
}

/// A table view wrapper that displays the timeline of a room.
struct TimelineViewRepresentable: UIViewControllerRepresentable {
    @EnvironmentObject private var viewModelContext: TimelineViewModel.Context

    func makeUIViewController(context: Context) -> TimelineTableViewController {
        TimelineTableViewController(coordinator: context.coordinator,
                                    isScrolledToBottom: $viewModelContext.isScrolledToBottom,
                                    scrollToBottomPublisher: viewModelContext.viewState.timelineState.scrollToBottomPublisher)
    }
    
    func updateUIViewController(_ uiViewController: TimelineTableViewController, context: Context) {
        context.coordinator.update(tableViewController: uiViewController)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModelContext: viewModelContext)
    }
    
    // MARK: - Coordinator
    
    @MainActor
    class Coordinator {
        let context: TimelineViewModel.Context
        
        init(viewModelContext: TimelineViewModel.Context) {
            context = viewModelContext
        }
        
        /// Updates the specified table view's properties from the current view state.
        func update(tableViewController: TimelineTableViewController) {
            if tableViewController.isSwitchingTimelines != context.viewState.timelineState.isSwitchingTimelines {
                // Must come before timelineItemsDictionary in order to disable animations.
                tableViewController.isSwitchingTimelines = context.viewState.timelineState.isSwitchingTimelines
            }
            if tableViewController.timelineItemsDictionary != context.viewState.timelineState.itemsDictionary {
                tableViewController.timelineItemsDictionary = context.viewState.timelineState.itemsDictionary
            }
            if tableViewController.paginationState != context.viewState.timelineState.paginationState {
                tableViewController.paginationState = context.viewState.timelineState.paginationState
            }
            if tableViewController.isLive != context.viewState.timelineState.isLive {
                tableViewController.isLive = context.viewState.timelineState.isLive
            }
            if tableViewController.focussedEvent != context.viewState.timelineState.focussedEvent {
                tableViewController.focussedEvent = context.viewState.timelineState.focussedEvent
            }
            if tableViewController.hideTimelineMedia != context.viewState.hideTimelineMedia {
                tableViewController.hideTimelineMedia = context.viewState.hideTimelineMedia
            }
            
            if tableViewController.typingMembers.members != context.viewState.typingMembers {
                tableViewController.setTypingMembers(context.viewState.typingMembers)
            }
        }
        
        func send(viewAction: TimelineViewAction) {
            context.send(viewAction: viewAction)
        }
    }
}

// MARK: - Previews

struct TimelineView_Previews: PreviewProvider, TestablePreview {
    static let roomProxyMock = JoinedRoomProxyMock(.init(id: "stable_id",
                                                         name: "Preview room"))
    static let roomViewModel = RoomScreenViewModel.mock(roomProxyMock: roomProxyMock)
    static let timelineViewModel = TimelineViewModel(roomProxy: roomProxyMock,
                                                     timelineController: MockTimelineController(),
                                                     userSession: UserSessionMock(.init()),
                                                     mediaPlayerProvider: MediaPlayerProviderMock(),
                                                     userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                     appMediator: AppMediatorMock.default,
                                                     appSettings: ServiceLocator.shared.settings,
                                                     analyticsService: ServiceLocator.shared.analytics,
                                                     emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                                     linkMetadataProvider: LinkMetadataProvider(),
                                                     timelineControllerFactory: TimelineControllerFactoryMock(.init()))

    static var previews: some View {
        NavigationStack {
            RoomScreen(context: roomViewModel.context,
                       timelineContext: timelineViewModel.context,
                       composerToolbar: ComposerToolbar.mock())
        }
    }
}
