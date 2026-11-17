//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct StickerPanelTab: View {
    static let tileSize: CGFloat = 72
    
    let context: ExpressionPanelViewModelType.Context
    
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(context.viewState.stickerSections) { section in
                            sectionView(section)
                                .id(section.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                
                ExpressionPanelBottomBar {
                    ForEach(context.viewState.stickerSections) { section in
                        Button {
                            withElementAnimation { proxy.scrollTo(section.id, anchor: .top) }
                        } label: {
                            sectionIcon(section)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(section.title)
                    }
                }
            }
        }
    }
    
    private func sectionView(_ section: StickerPanelSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.compound.bodySMSemibold)
                .foregroundStyle(.compound.textSecondary)
                .accessibilityAddTraits(.isHeader)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileSize, maximum: Self.tileSize * 1.3), spacing: 8)], spacing: 8) {
                if section.id == .recent {
                    createStickerTile
                }
                ForEach(section.items) { item in
                    StickerPanelTile(item: item,
                                     isSending: context.viewState.sendingStickerIDs.contains(item.id),
                                     mediaProvider: context.mediaProvider) { action in
                        context.send(viewAction: action)
                    }
                }
            }
        }
    }
    
    private var createStickerTile: some View {
        Button {
            context.send(viewAction: .createSticker)
        } label: {
            VStack(spacing: 2) {
                CompoundIcon(\.plus, size: .xSmall, relativeTo: .compound.bodyXS)
                    .foregroundStyle(.compound.iconPrimary)
                Text(UntranslatedL10n.guaStickerCreate)
                    .font(.compound.bodyXSSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.tileSize)
            .background(Color.compound.bgCanvasDefault, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(UntranslatedL10n.guaStickerCreate)
    }
    
    @ViewBuilder
    private func sectionIcon(_ section: StickerPanelSection) -> some View {
        switch section.id {
        case .recent:
            CompoundIcon(\.history, size: .medium, relativeTo: .compound.bodyLG)
                .foregroundStyle(.compound.iconSecondary)
        case .favourites:
            CompoundIcon(\.favourite, size: .medium, relativeTo: .compound.bodyLG)
                .foregroundStyle(.compound.iconSecondary)
        case .mine, .pack:
            if let source = section.iconURL.flatMap(URL.init(string:)).flatMap({ try? MediaSourceProxy(url: $0, mimeType: nil) }) {
                LoadableImage(mediaSource: source, size: CGSize(width: 96, height: 96), mediaProvider: context.mediaProvider) {
                    CompoundIcon(\.sticker, size: .medium, relativeTo: .compound.bodyLG)
                }
                .scaledToFit()
                .frame(width: 28, height: 28)
            } else {
                CompoundIcon(\.sticker, size: .medium, relativeTo: .compound.bodyLG)
                    .foregroundStyle(.compound.iconSecondary)
            }
        }
    }
}

private struct StickerPanelTile: View {
    let item: StickerPanelItem
    let isSending: Bool
    let mediaProvider: MediaProviderProtocol?
    let send: (ExpressionPanelViewAction) -> Void
    
    var body: some View {
        Button {
            send(.sendSticker(item))
        } label: {
            sticker
                .frame(height: StickerPanelTab.tileSize)
                .frame(maxWidth: .infinity)
                .overlay {
                    if isSending {
                        ProgressView()
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(actions, id: \.title) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    send(action.viewAction)
                } label: {
                    Text(action.title)
                }
            }
        } preview: {
            sticker
                .frame(width: 240, height: 240)
                .padding(16)
        }
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityActions {
            ForEach(actions, id: \.title) { action in
                Button(action.title) {
                    send(action.viewAction)
                }
            }
        }
    }
    
    @ViewBuilder
    private var sticker: some View {
        if let source = item.image.mediaSource {
            LoadableImage(mediaSource: source,
                          isAnimated: item.image.isAnimated,
                          size: CGSize(width: 216, height: 216),
                          mediaProvider: mediaProvider) {
                Color.compound.bgCanvasDefault.opacity(0.5)
            }
            .scaledToFit()
        }
    }
    
    private struct Action {
        let title: String
        let isDestructive: Bool
        let viewAction: ExpressionPanelViewAction
    }
    
    private var actions: [Action] {
        var actions = [item.isFavourite
            ? Action(title: UntranslatedL10n.guaStickerRemoveFavourite, isDestructive: false, viewAction: .unfavouriteSticker(url: item.image.url))
            : Action(title: UntranslatedL10n.guaStickerAddFavourite, isDestructive: false, viewAction: .favouriteSticker(item.image))]
        switch item.section {
        case .recent:
            actions.append(Action(title: UntranslatedL10n.guaStickerRemoveRecent, isDestructive: false, viewAction: .removeRecentSticker(url: item.image.url)))
        case .mine:
            if let shortcode = item.shortcode {
                actions.append(Action(title: L10n.actionDelete, isDestructive: true, viewAction: .deleteSticker(shortcode: shortcode)))
            }
        case .pack:
            actions.append(Action(title: UntranslatedL10n.guaStickerSave, isDestructive: false, viewAction: .saveSticker(item.image)))
        case .favourites:
            break
        }
        return actions
    }
}

extension StickerImage {
    var mediaSource: MediaSourceProxy? {
        URL(string: url).flatMap { try? MediaSourceProxy(url: $0, mimeType: info?.mimetype) }
    }
    
    var accessibilityLabel: String {
        "\(L10n.commonSticker), \(body ?? "")"
    }
}
