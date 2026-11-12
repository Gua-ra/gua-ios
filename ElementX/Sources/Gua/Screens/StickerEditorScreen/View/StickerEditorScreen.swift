//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct StickerEditorScreen: View {
    @Bindable var context: StickerEditorScreenViewModelType.Context
    
    @State private var gestureStartScale: CGFloat?
    @State private var gestureStartOffset: CGSize?
    
    var body: some View {
        ElementNavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    canvas
                    controls
                    buttons
                    if context.viewState.showsNote {
                        Text(UntranslatedL10n.guaStickerEditorNote)
                            .font(.compound.bodySM)
                            .foregroundStyle(.compound.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .readableFrame(maxWidth: 480)
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .navigationTitle(UntranslatedL10n.guaStickerCreate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.send(viewAction: .cancel)
                    }
                }
            }
        }
        .interactiveDismissDisabled(context.viewState.isSaving)
        .alert(item: $context.alertInfo)
    }
    
    private var canvas: some View {
        GeometryReader { geometry in
            let unit = StickerCanvas.side / max(geometry.size.width, 1)
            ZStack {
                Color.compound.bgSubtleSecondary
                if let preview = context.viewState.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                if context.viewState.isFindingSubjects {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(.rect)
            .gesture(framingGesture(unit: unit))
            .onTapGesture { location in
                context.send(viewAction: .tapCanvas(CGPoint(x: location.x * unit, y: location.y * unit)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
    
    private var controls: some View {
        VStack(spacing: 16) {
            Toggle(UntranslatedL10n.guaStickerEditorCutOut, isOn: Binding(get: { context.viewState.isCutOutEnabled },
                                                                          set: { context.send(viewAction: .setCutOut($0)) }))
                .toggleStyle(.compound)
                .disabled(!context.viewState.canCutOut)
            
            TextField(UntranslatedL10n.guaStickerEditorTextPlaceholder,
                      text: Binding(get: { context.viewState.text },
                                    set: { context.send(viewAction: .setText($0)) }))
                .font(.compound.bodyLG)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityLabel(L10n.commonText)
        }
    }
    
    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                context.send(viewAction: .send)
            } label: {
                Text(L10n.actionSend)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary))
            
            Button {
                context.send(viewAction: .save)
            } label: {
                Text(L10n.actionSave)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.secondary))
        }
        .disabled(context.viewState.isSaving)
        .overlay {
            if context.viewState.isSaving {
                ProgressView()
            }
        }
    }
    
    private func framingGesture(unit: CGFloat) -> some Gesture {
        SimultaneousGesture(DragGesture(minimumDistance: 4), MagnifyGesture())
            .onChanged { value in
                let startScale = gestureStartScale ?? context.viewState.scale
                let startOffset = gestureStartOffset ?? context.viewState.offset
                gestureStartScale = startScale
                gestureStartOffset = startOffset
                
                let scale = startScale * (value.second?.magnification ?? 1)
                let translation = value.first?.translation ?? .zero
                let offset = CGSize(width: startOffset.width + translation.width * unit,
                                    height: startOffset.height + translation.height * unit)
                context.send(viewAction: .setFraming(scale: scale, offset: offset))
            }
            .onEnded { _ in
                gestureStartScale = nil
                gestureStartOffset = nil
            }
    }
}

struct StickerEditorScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel: StickerEditorScreenViewModel = {
        let cutoutService = StickerCutoutServiceMock()
        cutoutService.cutoutOfReturnValue = StickerPreviewImages.cutout
        let viewModel = StickerEditorScreenViewModel(photo: StickerPreviewImages.photo,
                                                     cutoutService: cutoutService,
                                                     appSettings: AppSettings.volatile()) { _, _, _ in .success(()) }
        viewModel.context.send(viewAction: .setText("Good morning"))
        return viewModel
    }()
    
    static var previews: some View {
        StickerEditorScreen(context: viewModel.context)
            .snapshotPreferences(expect: viewModel.context.observe(\.viewState.isCutOutEnabled))
    }
}
