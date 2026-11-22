//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Cropped as in a chat that fills the screen.
struct ChatBackgroundPhotoPreview: View {
    @Bindable var context: ChatThemeScreenViewModel.Context

    @Environment(\.colorScheme) private var colorScheme
    /// Still drawn while the cover slides away, after the draft is cleared.
    @State private var lastDraft: ChatBackgroundPhotoDraft?

    var body: some View {
        NavigationStack {
            if let draft = context.viewState.bindings.photoDraft ?? lastDraft {
                ZStack(alignment: .bottom) {
                    ChatBackgroundPhotoFrame(draft: draft, bubble: context.viewState.baseTheme.bubble, onMove: move)
                        .environment(\.colorScheme, previewColorScheme(for: draft))
                        .ignoresSafeArea(edges: [.horizontal, .bottom])

                    VStack(spacing: 0) {
                        Text(UntranslatedL10n.guaChatBackgroundPositionHint)
                            .font(.compound.bodySMSemibold)
                            .foregroundColor(.compound.textPrimary)
                            .legibilityCapsule()
                            .environment(\.chatBackgroundActive, true)
                            .environment(\.colorScheme, previewColorScheme(for: draft))
                            .padding(16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)

                        controls(for: draft)
                    }
                }
                .navigationTitle(UntranslatedL10n.guaChatThemeWallpaper)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.actionCancel) {
                            context.send(viewAction: .discardPhoto)
                        }
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        .alert(item: $context.alertInfo)
        .onChange(of: context.viewState.bindings.photoDraft, initial: true) { _, draft in
            if let draft {
                lastDraft = draft
            }
        }
    }

    private func previewColorScheme(for draft: ChatBackgroundPhotoDraft) -> ColorScheme {
        draft.previewColorScheme ?? colorScheme
    }

    private func move(alignX: Double, alignY: Double) {
        context.send(viewAction: .movePhoto(alignX: alignX, alignY: alignY))
    }

    private func controls(for draft: ChatBackgroundPhotoDraft) -> some View {
        ChatThemePreviewControls(previewColorScheme: previewColorScheme(for: draft),
                                 saveTitle: UntranslatedL10n.guaChatThemeActionSet,
                                 canSave: context.viewState.canChange,
                                 onPreviewColorScheme: { context.send(viewAction: .setPreviewColorScheme($0)) },
                                 onSave: { context.send(viewAction: .setPhoto) },
                                 extra: { photoControls(for: draft) })
    }

    @ViewBuilder
    private func photoControls(for draft: ChatBackgroundPhotoDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(UntranslatedL10n.guaChatBackgroundDim)
                .font(.compound.bodyMDSemibold)
                .foregroundColor(.compound.textPrimary)

            Slider(value: Binding { draft.dim } set: { context.send(viewAction: .setPhotoDim($0)) },
                   in: 0...ChatBackground.Photo.maxDim,
                   step: 0.05)
                .accessibilityLabel(UntranslatedL10n.guaChatBackgroundDim)
                .accessibilityValue(draft.dim.formatted(.percent.precision(.fractionLength(0))))
        }

        Text(UntranslatedL10n.guaChatBackgroundPhotoNote)
            .font(.compound.bodySM)
            .foregroundColor(.compound.textSecondary)
    }
}

struct ChatBackgroundPhotoFrame: View {
    let draft: ChatBackgroundPhotoDraft
    let bubble: ChatBubbleColor
    let onMove: (_ alignX: Double, _ alignY: Double) -> Void

    @State private var dragStart: (alignX: Double, alignY: Double)?

    private let nudge = 0.1

    var body: some View {
        GeometryReader { geometry in
            let overflow = overflow(in: geometry.size)

            ZStack(alignment: .top) {
                Color.compound.bgCanvasDefault
                ChatBackgroundPhotoLayout(image: draft.image, alignX: draft.alignX, alignY: draft.alignY)
                ChatBackgroundScrim(photoDim: draft.dim)

                ChatThemeSampleMessages(isOnBackground: true, bubble: bubble)
                    .allowsHitTesting(false)
            }
            .environment(\.layoutDirection, .leftToRight)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let start = dragStart ?? (draft.alignX, draft.alignY)
                dragStart = start
                // Dragging right moves the photo right, which is a smaller align: the offset is -overflow × align.
                let alignX = overflow.width > 0 ? start.alignX - value.translation.width / overflow.width : start.alignX
                let alignY = overflow.height > 0 ? start.alignY - value.translation.height / overflow.height : start.alignY
                onMove(alignX, alignY)
            }
            .onEnded { _ in
                dragStart = nil
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UntranslatedL10n.guaChatBackgroundPreviewA11y)
            .accessibilityHint(UntranslatedL10n.guaChatBackgroundPositionHint)
            .accessibilityAction(named: UntranslatedL10n.guaChatBackgroundA11yMoveLeft) { onMove(draft.alignX + nudge, draft.alignY) }
            .accessibilityAction(named: UntranslatedL10n.guaChatBackgroundA11yMoveRight) { onMove(draft.alignX - nudge, draft.alignY) }
            .accessibilityAction(named: UntranslatedL10n.guaChatBackgroundA11yMoveUp) { onMove(draft.alignX, draft.alignY + nudge) }
            .accessibilityAction(named: UntranslatedL10n.guaChatBackgroundA11yMoveDown) { onMove(draft.alignX, draft.alignY - nudge) }
        }
    }

    private func overflow(in frame: CGSize) -> CGSize {
        let scaled = ChatBackgroundPhotoLayout.scaledSize(of: draft.image.size, filling: frame)
        return CGSize(width: scaled.width - frame.width, height: scaled.height - frame.height)
    }
}

struct ChatBackgroundPhotoPreview_Previews: PreviewProvider, TestablePreview {
    static let lightViewModel = makeViewModel(previewColorScheme: .light)
    static let darkViewModel = makeViewModel(previewColorScheme: .dark)

    static var previews: some View {
        ChatBackgroundPhotoPreview(context: lightViewModel.context)
            .previewDisplayName("Light")

        ChatBackgroundPhotoPreview(context: darkViewModel.context)
            .previewDisplayName("Dark")
    }

    static func makeViewModel(previewColorScheme: ColorScheme) -> ChatThemeScreenViewModel {
        let viewModel = ChatThemeScreen_Previews.makeViewModel(theme: .init(wallpaper: .none, bubble: .purple))
        if let url = Bundle.main.url(forResource: "preview_image", withExtension: "jpg"),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            let upload = ChatBackgroundPhotoUpload(data: data, width: Int(image.size.width), height: Int(image.size.height), blurhash: nil)
            viewModel.context.photoDraft = ChatBackgroundPhotoDraft(upload: upload, image: image, alignX: 0.3, previewColorScheme: previewColorScheme)
        }
        return viewModel
    }
}
