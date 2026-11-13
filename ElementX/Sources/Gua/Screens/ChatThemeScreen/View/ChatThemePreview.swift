//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatThemePreview: View {
    @Bindable var context: ChatThemeScreenViewModel.Context
    let draft: ChatThemePreviewDraft
    let saveTitle: String

    @Environment(\.colorScheme) private var colorScheme

    private var previewColorScheme: ColorScheme {
        draft.previewColorScheme ?? colorScheme
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ChatThemeSampleMessages(theme: draft.shownTheme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background {
                        ChatBackgroundView(background: draft.shownTheme.wallpaper, mediaProvider: context.mediaProvider)
                    }
                    .environment(\.colorScheme, previewColorScheme)
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(UntranslatedL10n.guaChatBackgroundPreviewA11y)
                    .accessibilityValue(draft.shownTheme.displayName)

                ChatThemePreviewControls(previewColorScheme: previewColorScheme,
                                         saveTitle: saveTitle,
                                         canSave: context.viewState.canSave(draft),
                                         onPreviewColorScheme: { context.send(viewAction: .setPreviewColorScheme($0)) },
                                         onSave: { context.send(viewAction: .savePreview) })
            }
            .navigationTitle(UntranslatedL10n.guaChatThemeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.send(viewAction: .cancelPreview)
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .alert(item: $context.alertInfo)
    }
}

struct ChatThemePreviewControls<Extra: View>: View {
    let previewColorScheme: ColorScheme
    let saveTitle: String
    let canSave: Bool
    let onPreviewColorScheme: (ColorScheme) -> Void
    let onSave: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(UntranslatedL10n.guaChatBackgroundPreviewA11y, selection: Binding { previewColorScheme } set: { onPreviewColorScheme($0) }) {
                Text(UntranslatedL10n.guaChatBackgroundPreviewLight).tag(ColorScheme.light)
                Text(UntranslatedL10n.guaChatBackgroundPreviewDark).tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)

            extra

            Button(saveTitle, action: onSave)
                .buttonStyle(.compound(.primary))
                .disabled(!canSave)
        }
        .padding(16)
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
    }
}

extension ChatThemePreviewControls where Extra == EmptyView {
    init(previewColorScheme: ColorScheme,
         saveTitle: String,
         canSave: Bool,
         onPreviewColorScheme: @escaping (ColorScheme) -> Void,
         onSave: @escaping () -> Void) {
        self.init(previewColorScheme: previewColorScheme,
                  saveTitle: saveTitle,
                  canSave: canSave,
                  onPreviewColorScheme: onPreviewColorScheme,
                  onSave: onSave) {
            EmptyView()
        }
    }
}

struct ChatThemePreview_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ChatThemeScreen_Previews.makeViewModel(theme: .stock)

    static var previews: some View {
        ChatThemePreview(context: viewModel.context,
                         draft: .init(theme: .init(wallpaper: .preset(.dawn), bubble: .blue),
                                      shownTheme: .init(wallpaper: .preset(.dawn), bubble: .blue),
                                      previewColorScheme: .light),
                         saveTitle: UntranslatedL10n.guaChatThemeActionSetTheme)
            .previewDisplayName("Light")

        ChatThemePreview(context: viewModel.context,
                         draft: .init(theme: .init(wallpaper: .preset(.forest), bubble: .green),
                                      shownTheme: .init(wallpaper: .preset(.forest), bubble: .green),
                                      previewColorScheme: .dark),
                         saveTitle: UntranslatedL10n.guaChatThemeActionSetDefault)
            .previewDisplayName("Dark")
    }
}
