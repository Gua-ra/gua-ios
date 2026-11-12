//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct GifPreviewSheet: View {
    @Bindable var context: ExpressionPanelViewModelType.Context
    
    var body: some View {
        if let preview = context.gifPreview {
            VStack(spacing: 16) {
                ZStack(alignment: .topTrailing) {
                    if let file = preview.item.sendChoice?.animated ?? preview.item.preview?.animated {
                        GifImage(file: file, provider: context.viewState.gifProvider)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel(preview.item.accessibilityLabel)
                    }
                    favouriteButton(preview.item)
                }
                .frame(maxHeight: 320)
                
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(L10n.richTextEditorComposerCaptionPlaceholder, text: captionBinding, axis: .vertical)
                        .font(.compound.bodyLG)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.compound.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 20))
                    
                    SendButton(mode: .send) {
                        context.send(viewAction: .sendGif)
                    }
                    .disabled(preview.isSending)
                    .accessibilityLabel(L10n.actionSend)
                    .overlay {
                        if preview.isSending {
                            ProgressView()
                        }
                    }
                }
            }
            .padding(16)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
    
    private var captionBinding: Binding<String> {
        Binding(get: { context.gifPreview?.caption ?? "" },
                set: { context.gifPreview?.caption = $0 })
    }
    
    private func favouriteButton(_ item: GifItem) -> some View {
        let isFavourite = context.viewState.gifFavouriteIDs.contains(item.id)
        return Button {
            context.send(viewAction: .toggleGifFavourite(item))
        } label: {
            CompoundIcon(isFavourite ? \.favouriteSolid : \.favourite, size: .medium, relativeTo: .compound.bodyLG)
                .foregroundStyle(.compound.iconOnSolidPrimary)
                .padding(10)
                .background(.black.opacity(0.5), in: .circle)
                .padding(8)
        }
        .accessibilityLabel(isFavourite ? UntranslatedL10n.guaStickerRemoveFavourite : UntranslatedL10n.guaStickerAddFavourite)
    }
}

struct GifPreviewSheet_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ExpressionPanelPreviewFixtures.gifPreviewViewModel()
    
    static var previews: some View {
        GifPreviewSheet(context: viewModel.context)
            .environment(\.gifPreviewImages, ExpressionPanelPreviewFixtures.gifImages)
    }
}
