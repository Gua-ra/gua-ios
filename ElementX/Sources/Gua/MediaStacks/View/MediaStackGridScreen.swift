//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct MediaStackGridScreen: View {
    @ObservedObject var context: TimelineViewModel.Context
    let stack: MediaStackRoomTimelineItem
    
    var body: some View {
        ElementNavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: columns(for: geometry.size.width), spacing: 2) {
                        ForEach(stack.members.indices, id: \.self) { index in
                            let member = stack.members[index]
                            MediaStackGridTile(member: member, accessibilityLabel: stack.positionDescription(at: index))
                                .onTapGesture {
                                    context.send(viewAction: .mediaTapped(itemID: member.id))
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
    let member: MediaStackRoomTimelineItem.Member
    let accessibilityLabel: String
    
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { MediaStackThumbnail(member: member, style: .tile) }
            .clipped()
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }
}

struct MediaStackGridScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    
    static var previews: some View {
        MediaStackGridScreen(context: viewModel.context, stack: MediaStackRoomTimelineView_Previews.outgoingMixed)
    }
}
