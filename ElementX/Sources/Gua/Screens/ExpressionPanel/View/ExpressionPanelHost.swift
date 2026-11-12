//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

extension EnvironmentValues {
    /// Room kept clear at the trailing edge of the composer's text for the expression button.
    @Entry var composerTrailingInset: CGFloat = 0
    @Entry var supportsStickerGlyphs = false
}

extension View {
    func expressionPanelHost(_ context: ExpressionPanelViewModelType.Context?, composerFocused: FocusState<Bool>.Binding) -> some View {
        modifier(ExpressionPanelHost(context: context, composerFocused: composerFocused))
    }
    
    func expressionButton(_ context: ExpressionPanelViewModelType.Context?, composerFocused: FocusState<Bool>.Binding, isEnabled: Bool) -> some View {
        modifier(ExpressionButtonModifier(context: isEnabled ? context : nil, composerFocused: composerFocused))
    }
}

private struct ExpressionPanelHost: ViewModifier {
    let context: ExpressionPanelViewModelType.Context?
    let composerFocused: FocusState<Bool>.Binding
    
    func body(content: Content) -> some View {
        if let context {
            VStack(spacing: 0) {
                content
                if context.viewState.presentation != .hidden {
                    ExpressionPanel(context: context)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.elementDefault, value: context.viewState.presentation)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                // A hardware keyboard only shows its shortcuts bar, which is no height for the panel.
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, frame.height >= 200 else { return }
                context.send(viewAction: .keyboardHeightChanged(frame.height))
            }
            .onChange(of: composerFocused.wrappedValue) { _, isFocused in
                if isFocused, context.viewState.presentation != .hidden {
                    context.send(viewAction: .setPresentation(.hidden))
                }
            }
            .onDisappear {
                context.send(viewAction: .setPresentation(.hidden))
            }
        } else {
            content
        }
    }
}

private struct ExpressionButtonModifier: ViewModifier {
    let context: ExpressionPanelViewModelType.Context?
    let composerFocused: FocusState<Bool>.Binding
    
    func body(content: Content) -> some View {
        if let context {
            content
                .environment(\.composerTrailingInset, 28)
                .environment(\.supportsStickerGlyphs, true)
                .overlay(alignment: .bottomTrailing) {
                    ExpressionButton(context: context, composerFocused: composerFocused)
                }
        } else {
            content
        }
    }
}

private struct ExpressionButton: View {
    let context: ExpressionPanelViewModelType.Context
    let composerFocused: FocusState<Bool>.Binding
    
    private var isPanelVisible: Bool {
        context.viewState.presentation != .hidden
    }
    
    var body: some View {
        Button {
            if isPanelVisible {
                context.send(viewAction: .setPresentation(.hidden))
                composerFocused.wrappedValue = true
            } else {
                composerFocused.wrappedValue = false
                context.send(viewAction: .setPresentation(.compact))
            }
        } label: {
            CompoundIcon(isPanelVisible ? \.keyboard : \.sticker, size: .medium, relativeTo: .compound.bodyLG)
                .foregroundStyle(.compound.iconSecondary)
                .frame(width: 44, height: Compound.supportsGlass ? 44 : 42)
                .contentShape(.rect)
        }
        .accessibilityLabel(isPanelVisible ? UntranslatedL10n.guaExpressionKeyboardA11y : UntranslatedL10n.guaExpressionOpenA11y)
    }
}
