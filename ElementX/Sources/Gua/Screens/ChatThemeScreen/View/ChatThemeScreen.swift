//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatThemeScreen: View {
    @Bindable var context: ChatThemeScreenViewModel.Context

    private var viewState: ChatThemeScreenViewState {
        context.viewState
    }

    var body: some View {
        Form {
            Section {
                ListRow(kind: .custom {
                    HStack(alignment: .top, spacing: 40) {
                        ChatThemeRoundButton(title: UntranslatedL10n.guaChatThemeChatBubble, value: viewState.current.bubble.name) {
                            ZStack {
                                viewState.current.bubble.outgoingColor
                                CompoundIcon(\.chatSolid)
                                    .foregroundStyle(.compound.iconSecondary)
                            }
                        } action: {
                            context.send(viewAction: .presentBubblePicker)
                        }

                        ChatThemeRoundButton(title: UntranslatedL10n.guaChatThemeWallpaper, value: viewState.current.wallpaper.displayName) {
                            ChatBackgroundView(background: viewState.shownWallpaper, mediaProvider: context.mediaProvider)
                        } action: {
                            context.send(viewAction: .presentWallpaperPicker)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .disabled(!viewState.canChange)
                })
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewState.note)
                    if !viewState.canChange {
                        Text(UntranslatedL10n.guaChatBackgroundRowNoPermission)
                    }
                }
                .compoundListSectionFooter()
            }

            ForEach(viewState.sections) { section in
                Section {
                    ListRow(kind: .custom {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    if section.id == .featured {
                                        ChatThemeTile(theme: viewState.firstTileTheme,
                                                      name: viewState.firstTileName,
                                                      isSelected: viewState.current.isStock,
                                                      mediaProvider: context.mediaProvider) {
                                            context.send(viewAction: .selectFirstTile)
                                        }
                                    }

                                    ForEach(section.themes, id: \.self) { theme in
                                        ChatThemeTile(theme: theme, name: nil, isSelected: theme == viewState.current, mediaProvider: context.mediaProvider) {
                                            context.send(viewAction: .selectTheme(theme))
                                        }
                                    }
                                }
                                .padding(16)
                                .disabled(!viewState.canChange)
                            }
                            .scrollIndicators(.hidden)
                            .onAppear {
                                proxy.scrollTo(viewState.current, anchor: .center)
                            }
                        }
                    })
                } header: {
                    Text(section.title)
                        .compoundListSectionHeader()
                }
            }
        }
        .compoundList()
        .navigationTitle(UntranslatedL10n.guaChatThemeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo.presented(if: viewState.bindings.isScreenTopmost))
        .fullScreenCover(item: $context.themePreview) { draft in
            ChatThemePreview(context: context, draft: draft, saveTitle: viewState.setThemeTitle)
        }
        .sheet(isPresented: isBubblePickerPresented) {
            ChatBubblePicker(context: context)
        }
        .sheet(isPresented: $context.isWallpaperPickerPresented) {
            ChatWallpaperPicker(context: context)
        }
    }

    private var isBubblePickerPresented: Binding<Bool> {
        Binding {
            context.bubbleChoice != nil
        } set: { isPresented in
            if !isPresented {
                context.bubbleChoice = nil
            }
        }
    }
}

extension Binding where Value == AlertInfo<ChatThemeScreenAlertType>? {
    /// Every layer that can raise the alert binds to it, and only the one on top may present it.
    func presented(if isTopmost: Bool) -> Binding<Value> {
        Binding {
            isTopmost ? wrappedValue : nil
        } set: { newValue in
            wrappedValue = newValue
        }
    }
}

private struct ChatThemeRoundButton<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: Content
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric private var size = 64.0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                content
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.compound.borderInteractiveSecondary, lineWidth: 1)
                    }

                Text(title)
                    .font(.compound.bodySMSemibold)
                    .foregroundStyle(isEnabled ? .compound.textPrimary : .compound.textDisabled)
                    .multilineTextAlignment(.center)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
    }
}

struct ChatThemeTile: View {
    let theme: ChatTheme
    /// Only the Default and Classic tiles carry a name.
    let name: String?
    let isSelected: Bool
    let mediaProvider: MediaProviderProtocol?
    let action: () -> Void

    @ScaledMetric private var width = 84.0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                sampleBubble(color: .compound._bgBubbleIncoming, width: 0.55, alignment: .leading)
                sampleBubble(color: theme.bubble.outgoingColor, width: 0.65, alignment: .trailing)
                Spacer(minLength: 0)

                if let name {
                    Text(name)
                        .font(.compound.bodyXSSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(1)
                        .legibilityCapsule()
                }
            }
            .padding(8)
            .frame(width: width, height: width * 16 / 9)
            .background {
                ChatBackgroundView(background: theme.wallpaper, mediaProvider: mediaProvider)
            }
            .chatTheme(theme)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.compound.borderInteractivePrimary : Color.compound.borderInteractiveSecondary,
                                  lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    CompoundIcon(\.checkCircleSolid)
                        .foregroundStyle(.compound.iconAccentPrimary)
                        .background(Circle().fill(Color.compound.bgCanvasDefault))
                        .padding(6)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name ?? theme.wallpaper.displayName)
        .accessibilityValue(name == nil ? theme.bubble.name : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func sampleBubble(color: Color, width fraction: CGFloat, alignment: Alignment) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: (width - 16) * fraction, height: 14)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct ChatThemePreviewCard: View {
    let theme: ChatTheme
    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        ChatThemeSampleMessages(theme: theme)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
            .background {
                ChatBackgroundView(background: theme.wallpaper, mediaProvider: mediaProvider)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.compound.borderInteractiveSecondary, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UntranslatedL10n.guaChatBackgroundPreviewA11y)
            .accessibilityValue(theme.displayName)
    }
}

struct ChatThemeSampleMessages: View {
    let isOnBackground: Bool
    let bubble: ChatBubbleColor

    init(theme: ChatTheme) {
        self.init(isOnBackground: !theme.wallpaper.isNone, bubble: theme.bubble)
    }

    init(isOnBackground: Bool, bubble: ChatBubbleColor) {
        self.isOnBackground = isOnBackground
        self.bubble = bubble
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(UntranslatedL10n.guaChatBackgroundSampleToday)
                .font(.compound.bodySMSemibold)
                .foregroundColor(.compound.textPrimary)
                .legibilityCapsule()

            HStack(spacing: 0) {
                bubble(UntranslatedL10n.guaChatBackgroundSampleIncoming, isOutgoing: false)
                Spacer(minLength: 48)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 48)
                bubble(UntranslatedL10n.guaChatBackgroundSampleOutgoing, isOutgoing: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .environment(\.chatBackgroundActive, isOnBackground)
    }

    private func bubble(_ text: String, isOutgoing: Bool) -> some View {
        Text(text)
            .font(.compound.bodyLG)
            .foregroundColor(.compound.textPrimary)
            .bubbleBackground(isOutgoing: isOutgoing, color: isOutgoing ? bubble.outgoingColor : .compound._bgBubbleIncoming)
    }
}

struct ChatThemeScreen_Previews: PreviewProvider, TestablePreview {
    static let chatViewModel = makeViewModel(theme: .init(wallpaper: .preset(.ocean), bubble: .teal),
                                             defaultTheme: .init(wallpaper: .preset(.aurora), bubble: .green))
    static let followingDefaultViewModel = makeViewModel(theme: .stock, defaultTheme: .init(wallpaper: .preset(.dusk), bubble: .orange))
    static let defaultViewModel = makeViewModel(mode: .defaultTheme, theme: .init(wallpaper: .preset(.night), bubble: .purple))
    static let noPermissionViewModel = makeViewModel(theme: .init(wallpaper: .preset(.sunset), bubble: .pink), canChange: false)

    static var previews: some View {
        NavigationStack {
            ChatThemeScreen(context: chatViewModel.context)
        }
        .previewDisplayName("Chat")

        NavigationStack {
            ChatThemeScreen(context: followingDefaultViewModel.context)
        }
        .previewDisplayName("Chat following the default")

        NavigationStack {
            ChatThemeScreen(context: defaultViewModel.context)
        }
        .previewDisplayName("Default")

        NavigationStack {
            ChatThemeScreen(context: noPermissionViewModel.context)
        }
        .previewDisplayName("No permission")

        NavigationStack {
            ChatThemeScreen(context: chatViewModel.context)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .previewDisplayName("Dark")
    }

    enum Mode {
        case chat
        case defaultTheme
    }

    static func makeViewModel(mode: Mode = .chat,
                              theme: ChatTheme,
                              defaultTheme: ChatTheme = .stock,
                              canChange: Bool = true) -> ChatThemeScreenViewModel {
        let roomProxy = JoinedRoomProxyMock(.init(id: "chat_theme_room", members: [canChange ? .mockMeAdmin : .mockMe, .mockAlice]))
        let service = switch mode {
        case .chat:
            ChatBackgroundServiceMock(.init(theme: theme, defaultTheme: defaultTheme))
        case .defaultTheme:
            ChatBackgroundServiceMock(.init(defaultTheme: theme))
        }
        return ChatThemeScreenViewModel(mode: mode == .chat ? .chat(roomProxy) : .defaultTheme,
                                        clientProxy: ClientProxyMock(.init()),
                                        chatBackgroundService: service,
                                        userIndicatorController: UserIndicatorControllerMock(),
                                        mediaProvider: MediaProviderMock(configuration: .init()))
    }
}
