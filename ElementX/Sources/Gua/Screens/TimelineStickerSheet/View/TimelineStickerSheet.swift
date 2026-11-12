//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct TimelineStickerSheet: View {
    @Bindable var context: TimelineStickerSheetViewModelType.Context
    
    var body: some View {
        VStack(spacing: 16) {
            sticker
            
            if let packName = context.viewState.packName {
                Text(UntranslatedL10n.guaStickerFromPack(packName))
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
            }
            
            VStack(spacing: 12) {
                if !context.viewState.isSaved {
                    Button {
                        context.send(viewAction: .save)
                    } label: {
                        Text(UntranslatedL10n.guaStickerSave)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.compound(.primary))
                }
                
                Button {
                    context.send(viewAction: .toggleFavourite)
                } label: {
                    Text(context.viewState.isFavourite ? UntranslatedL10n.guaStickerRemoveFavourite : UntranslatedL10n.guaStickerAddFavourite)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.compound(.secondary))
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .alert(item: $context.alertInfo)
    }
    
    @ViewBuilder
    private var sticker: some View {
        let image = context.viewState.image
        if let source = image.mediaSource {
            LoadableImage(mediaSource: source, isAnimated: image.isAnimated, mediaProvider: context.mediaProvider) {
                Color.compound.bgSubtleSecondary
            }
            .scaledToFit()
            .frame(width: 200, height: 200)
            .accessibilityLabel(image.accessibilityLabel)
        }
    }
}

struct TimelineStickerSheet_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    
    static var previews: some View {
        TimelineStickerSheet(context: viewModel.context)
    }
    
    static func makeViewModel() -> TimelineStickerSheetViewModel {
        let packClient = StickerPackClientMock()
        packClient.packEventsRoomIDReturnValue = .success([])
        let directory = FileManager.default.temporaryDirectory.appending(path: "timeline-sticker-sheet-preview")
        return TimelineStickerSheetViewModel(image: StickerImage(url: "mxc://gua.global/sticker1", body: "Waving cat", info: nil),
                                             library: StickerLibrarySetting(clientProxy: ClientProxyMock(.init()), cache: AccountDataCache(directory: directory)),
                                             packClient: packClient,
                                             roomProxy: JoinedRoomProxyMock(.init(name: "Family")),
                                             mediaProvider: ExpressionPanelPreviewFixtures.mediaProvider)
    }
}
