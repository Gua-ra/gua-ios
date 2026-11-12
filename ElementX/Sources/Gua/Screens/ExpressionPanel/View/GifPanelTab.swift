//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct GifPanelTab: View {
    let context: ExpressionPanelViewModelType.Context
    
    var body: some View {
        VStack(spacing: 0) {
            switch context.viewState.gifContent {
            case .unavailable:
                message(UntranslatedL10n.guaGifsUnavailable)
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 16) {
                    message(UntranslatedL10n.guaGifsLoadError)
                    Button(L10n.actionTryAgain) {
                        context.send(viewAction: .retryGifs)
                    }
                    .buttonStyle(.compound(.secondary, size: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ScrollView {
                    GifMasonry(items: context.viewState.gifItems,
                               provider: context.viewState.gifProvider,
                               favouriteIDs: context.viewState.gifFavouriteIDs,
                               hasNextPage: context.viewState.gifHasNextPage) { action in
                        context.send(viewAction: action)
                    }
                    .padding(.horizontal, 12)
                }
            }
            
            if context.viewState.gifContent != .unavailable {
                bottomBar
            }
        }
    }
    
    private func message(_ text: String) -> some View {
        Text(text)
            .font(.compound.bodyMD)
            .foregroundStyle(.compound.textSecondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var bottomBar: some View {
        ExpressionPanelBottomBar {
            sourceButton(.recent, icon: \.history, label: UntranslatedL10n.guaExpressionRecent)
            sourceButton(.favourites, icon: \.favourite, label: UntranslatedL10n.guaExpressionFavourites)
            sourceButton(.trending, icon: \.chart, label: UntranslatedL10n.guaGifsTrending)
            ForEach(ExpressionWord.moods, id: \.self) { mood in
                Button(mood.text) {
                    context.send(viewAction: .selectWord(mood))
                }
                .font(.compound.bodySMSemibold)
                .foregroundStyle(context.viewState.gifSource == .search(mood.text) ? .compound.textActionAccent : .compound.textSecondary)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
            }
        }
    }
    
    private func sourceButton(_ source: GifPanelSource, icon: KeyPath<CompoundIcons, Image>, label: String) -> some View {
        Button {
            context.send(viewAction: .selectGifSource(source))
        } label: {
            CompoundIcon(icon, size: .medium, relativeTo: .compound.bodyLG)
                .foregroundStyle(context.viewState.gifSource == source ? .compound.iconAccentPrimary : .compound.iconSecondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(context.viewState.gifSource == source ? .isSelected : [])
    }
}

private struct GifMasonry: View {
    let items: [GifItem]
    let provider: GifProvider
    let favouriteIDs: Set<String>
    let hasNextPage: Bool
    let send: (ExpressionPanelViewAction) -> Void
    
    var body: some View {
        let columns = Self.columns(of: items)
        HStack(alignment: .top, spacing: 8) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(spacing: 8) {
                    ForEach(columns[index]) { item in
                        tile(item)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        
        if hasNextPage {
            ProgressView()
                .padding()
                .onAppear { send(.loadMoreGifs) }
        }
    }
    
    static func columns(of items: [GifItem]) -> [[GifItem]] {
        var columns: [[GifItem]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for item in items {
            let file = item.preview?.animated
            let ratio = CGFloat(file?.height ?? 1) / CGFloat(max(file?.width ?? 1, 1))
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(item)
            heights[column] += ratio
        }
        return columns
    }
    
    @ViewBuilder
    private func tile(_ item: GifItem) -> some View {
        if let preview = item.preview {
            Button {
                send(.openGif(item))
            } label: {
                GifImage(file: preview.animated, provider: provider)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture().onEnded { _ in
                send(.toggleGifFavourite(item))
            })
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityAction(named: favouriteIDs.contains(item.id) ? UntranslatedL10n.guaStickerRemoveFavourite : UntranslatedL10n.guaStickerAddFavourite) {
                send(.toggleGifFavourite(item))
            }
        }
    }
}

extension GifItem {
    var accessibilityLabel: String {
        "\(L10n.commonGif), \(title.isEmpty ? GifSendChoice.defaultBody : title)"
    }
}
