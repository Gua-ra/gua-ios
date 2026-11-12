//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import PhotosUI
import SwiftUI

struct ExpressionPanel: View {
    @Bindable var context: ExpressionPanelViewModelType.Context
    /// Previews have no window to measure.
    var screenHeight: CGFloat?
    
    @State private var dragTranslation: CGFloat = 0
    @State private var pickedPhoto: PhotosPickerItem?
    
    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            content
        }
        .frame(height: max(160, height(for: context.viewState.presentation) - dragTranslation))
        .frame(maxWidth: .infinity)
        .background(Color.compound.bgSubtleSecondary.ignoresSafeArea(edges: .bottom))
        .alert(item: $context.alertInfo)
        .sheet(item: $context.gifPreview) { _ in
            GifPreviewSheet(context: context)
        }
        .sheet(item: $context.stickerEditor) { editor in
            StickerEditorScreen(context: editor.context)
        }
        .photosPicker(isPresented: $context.isPhotoPickerPresented, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    context.send(viewAction: .pickedPhoto(data))
                }
            }
        }
    }
    
    private var heights: ExpressionPanelHeights {
        let window = screenHeight == nil ? Self.window : nil
        return ExpressionPanelHeights(screenHeight: screenHeight ?? window?.bounds.height ?? 800,
                                      keyboardHeight: context.viewState.keyboardHeight,
                                      bottomInset: window?.safeAreaInsets.bottom ?? 0)
    }
    
    private func height(for presentation: ExpressionPanelPresentation) -> CGFloat {
        presentation == .expanded ? heights.expanded : heights.opening
    }
    
    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }
    
    private var grabber: some View {
        Capsule()
            .fill(Color.compound.iconQuaternary)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(.rect)
            .gesture(DragGesture()
                .onChanged { dragTranslation = $0.translation.height }
                .onEnded { value in
                    dragTranslation = 0
                    settle(afterDragging: value.translation.height)
                })
            .accessibilityHidden(true)
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            Picker(selection: Binding(get: { context.viewState.tab }, set: { context.send(viewAction: .selectTab($0)) })) {
                Text(L10n.commonGif).tag(ExpressionPanelTab.gifs)
                Text(UntranslatedL10n.guaExpressionStickersTab).tag(ExpressionPanelTab.stickers)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            
            if !(context.viewState.tab == .gifs && context.viewState.gifContent == .unavailable) {
                searchField
                chips
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    private var searchField: some View {
        HStack(spacing: 8) {
            CompoundIcon(\.search, size: .small, relativeTo: .compound.bodyLG)
                .foregroundStyle(.compound.iconSecondary)
            TextField(context.viewState.searchPlaceholder,
                      text: Binding(get: { context.viewState.searchText }, set: { context.send(viewAction: .updateSearch($0)) }))
                .font(.compound.bodyLG)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.compound.bgCanvasDefault, in: .capsule)
    }
    
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ExpressionWord.chips, id: \.self) { word in
                    Button(word.text) {
                        context.send(viewAction: .selectWord(word))
                    }
                    .font(.compound.bodySMSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Color.compound.bgCanvasDefault, in: .capsule)
                }
            }
        }
    }
    
    @ViewBuilder
    private var content: some View {
        switch context.viewState.tab {
        case .stickers:
            StickerPanelTab(context: context)
        case .gifs:
            GifPanelTab(context: context)
        }
    }
    
    private func settle(afterDragging translation: CGFloat) {
        let height = height(for: context.viewState.presentation) - translation
        context.send(viewAction: .setPresentation(heights.presentation(afterDraggingTo: height)))
    }
}

struct ExpressionPanelBottomBar<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                content
            }
            .padding(.horizontal, 12)
        }
        .frame(minHeight: 48)
        .background(Color.compound.bgSubtleSecondary)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct ExpressionPanel_Previews: PreviewProvider, TestablePreview {
    static let stickersViewModel = ExpressionPanelPreviewFixtures.viewModel(tab: .stickers, withContent: true)
    static let emptyStickersViewModel = ExpressionPanelPreviewFixtures.viewModel(tab: .stickers, withContent: false)
    static let gifsViewModel = ExpressionPanelPreviewFixtures.viewModel(tab: .gifs, withContent: true)
    static let gifErrorViewModel = ExpressionPanelPreviewFixtures.viewModel(tab: .gifs, gifContent: .failed)
    static let gifUnavailableViewModel = ExpressionPanelPreviewFixtures.viewModel(tab: .gifs, gifContent: .unavailable)
    
    static var previews: some View {
        ExpressionPanel(context: stickersViewModel.context, screenHeight: screenHeight)
            .previewDisplayName("Stickers")
        ExpressionPanel(context: stickersViewModel.context, screenHeight: screenHeight)
            .dynamicTypeSize(.xxxLarge)
            .previewDisplayName("Stickers large text")
        ExpressionPanel(context: emptyStickersViewModel.context, screenHeight: screenHeight)
            .previewDisplayName("Stickers empty")
        ExpressionPanel(context: gifsViewModel.context, screenHeight: screenHeight)
            .environment(\.gifPreviewImages, ExpressionPanelPreviewFixtures.gifImages)
            .previewDisplayName("GIF results")
        ExpressionPanel(context: gifErrorViewModel.context, screenHeight: screenHeight)
            .previewDisplayName("GIF error")
        ExpressionPanel(context: gifUnavailableViewModel.context, screenHeight: screenHeight)
            .previewDisplayName("GIF unavailable")
    }
    
    /// The preview device's height, so the panel renders at its opening height.
    private static let screenHeight: CGFloat = 667
}
