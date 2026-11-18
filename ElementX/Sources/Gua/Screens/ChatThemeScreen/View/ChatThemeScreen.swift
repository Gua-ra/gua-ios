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
    
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isPhotoCreditsPresented = false
    
    private var viewState: ChatThemeScreenViewState {
        context.viewState
    }
    
    var body: some View {
        Form {
            Section {
                ListRow(kind: .custom {
                    HStack(alignment: .top, spacing: 40) {
                        ChatThemeRoundButton(title: UntranslatedL10n.guaChatThemeChatBubble, value: viewState.baseTheme.bubbles.name(in: colorScheme)) {
                            ZStack {
                                viewState.baseTheme.bubbles.outgoingColor
                                CompoundIcon(\.chatSolid)
                                    .foregroundStyle(.compound.iconSecondary)
                            }
                        } action: {
                            context.send(viewAction: .presentBubblePicker)
                        }
                        
                        ChatThemeRoundButton(title: UntranslatedL10n.guaChatThemeWallpaper, value: viewState.baseTheme.wallpaper.displayName) {
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
                    if let credit = viewState.photoCredit {
                        ChatPhotoCreditLine(credit: credit) {
                            isPhotoCreditsPresented = true
                        }
                    }
                }
                .compoundListSectionFooter()
            }
            
            ForEach(viewState.sections) { section in
                Section {
                    ListRow(kind: .custom {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    if section.id == .featured {
                                        ChatThemeTile(theme: viewState.firstTileTheme,
                                                      name: viewState.firstTileName,
                                                      isSelected: viewState.current.isStock,
                                                      mediaProvider: context.mediaProvider) {
                                            context.send(viewAction: .selectFirstTile)
                                        }
                                    }
                                    
                                    ForEach(section.themes, id: \.self) { theme in
                                        ChatThemeTile(theme: theme, name: nil, isSelected: viewState.isSelected(theme), mediaProvider: context.mediaProvider) {
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
                    ChatThemeSectionHeader(section: section.id) {
                        isPhotoCreditsPresented = true
                    }
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
        .chatPhotoCreditsSheet(isPresented: $isPhotoCreditsPresented)
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
    
    /// Capped so both circles fit one row on the narrowest phone at accessibility text sizes.
    private var diameter: CGFloat {
        min(size, 96)
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                content
                    .frame(width: diameter, height: diameter)
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
    
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var width = 84.0
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                tile
                
                if let credit {
                    VStack(spacing: 2) {
                        Text(theme.wallpaper.displayName)
                            .font(.compound.bodyXSSemibold)
                            .foregroundStyle(.compound.textPrimary)
                            .lineLimit(2)
                        // Wraps instead of truncating: the author's name must stay legible.
                        Text(UntranslatedL10n.guaChatThemePhotoCredit(credit.author))
                            .font(.compound.bodyXS)
                            .foregroundStyle(.compound.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .frame(width: width)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(name == nil ? theme.bubbles.name(in: colorScheme) : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
    
    private var tile: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            sampleBubble(color: .compound._bgBubbleIncoming, width: 0.55, alignment: .leading)
            sampleBubble(color: theme.bubbles.outgoingColor, width: 0.65, alignment: .trailing)
            Spacer(minLength: 0)
            
            // Not in a top corner: beside the selection checkmark there is no room for a translated badge.
            if isLive {
                ChatArtworkLiveBadge()
            }
            
            if let name {
                Text(name)
                    .font(.compound.bodyXSSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
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
    }
    
    private var isLive: Bool {
        theme.wallpaper.artwork?.isLive == true
    }
    
    private var credit: ChatArtwork.Credit? {
        theme.wallpaper.artwork?.credit
    }
    
    private var accessibilityLabel: String {
        let label = name ?? theme.wallpaper.displayName
        if let credit {
            return "\(label), \(UntranslatedL10n.guaChatThemePhotoCredit(credit.author))"
        }
        return isLive ? "\(label), \(UntranslatedL10n.guaChatThemeLiveBadge)" : label
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
    
    @Environment(\.colorScheme) private var colorScheme
    
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
            .accessibilityValue(theme.displayName(in: colorScheme))
    }
}

struct ChatThemeSampleMessages: View {
    let isOnBackground: Bool
    let bubbles: ChatBubblePair
    
    init(theme: ChatTheme) {
        self.init(isOnBackground: !theme.wallpaper.isNone, bubbles: theme.bubbles)
    }
    
    init(isOnBackground: Bool, bubbles: ChatBubblePair) {
        self.isOnBackground = isOnBackground
        self.bubbles = bubbles
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
            .bubbleBackground(isOutgoing: isOutgoing, color: isOutgoing ? bubbles.outgoingColor : .compound._bgBubbleIncoming)
    }
}

struct ChatThemeScreen_Previews: PreviewProvider, TestablePreview {
    static let chatViewModel = makeViewModel(theme: .init(wallpaper: .preset(.ocean), bubble: .teal),
                                             defaultTheme: .init(wallpaper: .preset(.aurora), bubble: .green))
    static let followingDefaultViewModel = makeViewModel(theme: .stock, defaultTheme: .init(wallpaper: .preset(.dusk), bubble: .orange))
    static let defaultViewModel = makeViewModel(mode: .defaultTheme, theme: .init(wallpaper: .preset(.night), bubble: .purple))
    static let noPermissionViewModel = makeViewModel(theme: .init(wallpaper: .preset(.sunset), bubble: .pink), canChange: false)
    static let artworkViewModel = makeViewModel(theme: .init(wallpaper: .art(.glassDrops), bubbles: ChatArtwork.glassDrops.bubbles))
    static let photoViewModel = makeViewModel(theme: .init(wallpaper: .art(.photoPeytoLake), bubbles: ChatArtwork.photoPeytoLake.bubbles), canChange: false)
    
    static var previews: some View {
        ElementNavigationStack {
            ChatThemeScreen(context: chatViewModel.context)
        }
        .previewDisplayName("Chat")
        
        ElementNavigationStack {
            ChatThemeScreen(context: followingDefaultViewModel.context)
        }
        .previewDisplayName("Chat following the default")
        
        ElementNavigationStack {
            ChatThemeScreen(context: defaultViewModel.context)
        }
        .previewDisplayName("Default")
        
        ElementNavigationStack {
            ChatThemeScreen(context: noPermissionViewModel.context)
        }
        .previewDisplayName("No permission")
        
        ElementNavigationStack {
            ChatThemeScreen(context: chatViewModel.context)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .previewDisplayName("Dark")
        
        ElementNavigationStack {
            ChatThemeScreen(context: artworkViewModel.context)
        }
        .previewDisplayName("Artwork")
        
        ElementNavigationStack {
            ChatThemeScreen(context: artworkViewModel.context)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .previewDisplayName("Artwork dark")
        
        ElementNavigationStack {
            ChatThemeScreen(context: photoViewModel.context)
        }
        .previewDisplayName("Photo")
        
        ElementNavigationStack {
            ChatThemeScreen(context: artworkViewModel.context)
        }
        .frame(height: 2100)
        .previewLayout(.sizeThatFits)
        .previewDisplayName("All sections")
        
        ElementNavigationStack {
            ChatThemeScreen(context: artworkViewModel.context)
        }
        .frame(height: 2100)
        .previewLayout(.sizeThatFits)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .previewDisplayName("All sections dark")
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
                                        mediaProvider: MediaProviderMock(.init()))
    }
}
