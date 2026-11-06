//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct MediaStackGridInfo: Identifiable {
    let stack: MediaStackRoomTimelineItem
    
    var id: TimelineItemIdentifier {
        stack.id
    }
}

struct MediaStackGridScreen: View {
    @ObservedObject var context: TimelineViewModel.Context
    let stack: MediaStackRoomTimelineItem
    
    var body: some View {
        ElementNavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: columns(for: geometry.size.width), spacing: 2) {
                        ForEach(stack.members.indices, id: \.self) { index in
                            MediaStackGridTile(member: stack.members[index], accessibilityLabel: stack.positionDescription(at: index))
                                .onTapGesture {
                                    context.send(viewAction: .mediaStackTapped(stackID: stack.id, index: index))
                                }
                        }
                    }
                }
            }
            .background(.compound.bgCanvasDefault)
            .navigationTitle(stack.countDescription)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ToolbarButton(role: .close) {
                        context.mediaStackGrid = nil
                    }
                }
            }
        }
        .environment(\.timelineContext, context)
        .timelineMediaPreview(viewModel: $context.mediaStackGridPreviewViewModel)
    }
    
    private func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: width > 600 ? 4 : 3)
    }
}

private struct MediaStackGridTile: View {
    @Environment(\.timelineContext) private var context
    
    let member: MediaStackRoomTimelineItem.Member
    let accessibilityLabel: String
    
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ContentScanningView(contentScannerService: context?.contentScannerService,
                                    mediaSource: member.mediaSource,
                                    thumbnailSource: member.thumbnailSource,
                                    containerShowsFailure: false) {
                    thumbnail
                } scanningContent: {
                    Color.compound.bgSubtleSecondary.overlay { ProgressView() }
                } unsafeContent: { failure in
                    ContentScanningFailureView(failure: failure)
                }
            }
            .overlay {
                if member.isVideo {
                    videoOverlay
                }
            }
            .clipped()
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }
    
    @ViewBuilder
    private var thumbnail: some View {
        if let source = member.stillSource {
            LoadableImage(mediaSource: source,
                          mediaType: .timelineItem(uniqueID: member.id.uniqueID),
                          blurhash: member.blurhash,
                          size: member.thumbnailSize,
                          mediaProvider: context?.mediaProvider) { image in
                image.scaledToFill()
            } placeholder: {
                Color.compound.bgSubtleSecondary
            }
        } else {
            Color.compound.bgSubtleSecondary
        }
    }
    
    private var videoOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            CompoundIcon(\.playSolid, size: .small, relativeTo: .compound.bodyMD)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: .circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            if let duration = member.duration {
                Text(MediaStackDuration.formatted(duration))
                    .font(.compound.bodyXSSemibold.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: .capsule)
                    .padding(6)
            }
        }
    }
}

struct MediaStackGridScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    
    static var previews: some View {
        MediaStackGridScreen(context: viewModel.context, stack: MediaStackRoomTimelineView_Previews.outgoingMixed)
    }
}
