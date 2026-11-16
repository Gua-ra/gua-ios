//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatBubblePicker: View {
    @Bindable var context: ChatThemeScreenViewModel.Context
    
    @ScaledMetric private var swatchSize = 44.0
    
    private var viewState: ChatThemeScreenViewState {
        context.viewState
    }
    
    /// Falls back to the saved bubbles while the sheet slides away.
    private var choice: ChatBubblePair {
        viewState.bindings.bubbleChoice ?? viewState.baseTheme.bubbles
    }
    
    private var savedTheme: ChatTheme {
        ChatTheme(wallpaper: viewState.baseTheme.wallpaper, bubbles: choice)
    }
    
    var body: some View {
        ElementNavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ChatThemePreviewCard(theme: viewState.shownTheme(saving: savedTheme), mediaProvider: context.mediaProvider)
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: swatchSize + 16), spacing: 8)], spacing: 16) {
                        ForEach(ChatBubbleColor.allCases) { bubble in
                            swatch(bubble)
                        }
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button(UntranslatedL10n.guaChatThemeActionSet) {
                    context.send(viewAction: .setBubble)
                }
                .buttonStyle(.compound(.primary))
                .disabled(!viewState.canSavePickerChoice(savedTheme))
                .padding(16)
                .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .navigationTitle(UntranslatedL10n.guaChatThemeChatBubble)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.bubbleChoice = nil
                    }
                }
            }
        }
        .alert(item: $context.alertInfo)
    }
    
    private func swatch(_ bubble: ChatBubbleColor) -> some View {
        let isSelected = bubble == choice.bubble
        // The selected swatch shows the theme's pair until a colour is chosen, which drops the dark one.
        let shown = isSelected ? choice : ChatBubblePair(bubble)
        
        return Button {
            context.send(viewAction: .chooseBubble(bubble))
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(shown.outgoingColor)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.compound.borderInteractiveSecondary, lineWidth: 1)
                    }
                    .frame(width: swatchSize, height: swatchSize)
                    .padding(4)
                    .overlay {
                        if isSelected {
                            Circle()
                                .strokeBorder(Color.compound.borderInteractivePrimary, lineWidth: 2)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            CompoundIcon(\.checkCircleSolid, size: .small, relativeTo: .compound.bodySM)
                                .foregroundStyle(.compound.iconAccentPrimary)
                                .background(Circle().fill(Color.compound.bgCanvasDefault))
                        }
                    }
                
                Text(bubble.name)
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!viewState.canChange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct ChatBubblePicker_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let pairViewModel = makeViewModel(theme: .init(wallpaper: .art(.glassDrops), bubbles: ChatArtwork.glassDrops.bubbles), choice: nil)
    
    static var previews: some View {
        ChatBubblePicker(context: viewModel.context)
            .previewDisplayName("Light")
        
        ChatBubblePicker(context: viewModel.context)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark")
        
        ChatBubblePicker(context: pairViewModel.context)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("Artwork pair dark")
    }
    
    static func makeViewModel(theme: ChatTheme = .init(wallpaper: .preset(.ocean), bubble: .teal), choice: ChatBubbleColor? = .blue) -> ChatThemeScreenViewModel {
        let viewModel = ChatThemeScreen_Previews.makeViewModel(theme: theme)
        viewModel.context.send(viewAction: .presentBubblePicker)
        if let choice {
            viewModel.context.send(viewAction: .chooseBubble(choice))
        }
        return viewModel
    }
}
