//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import Foundation
import Testing
import WysiwygComposer

@MainActor
final class StickerGlyphTextTests {
    private let cat = StickerGlyph(imageContent: Data([1]), contentIdentifier: "cat", contentDescription: "Cat")
    private let dog = StickerGlyph(imageContent: Data([2]), contentIdentifier: "dog", contentDescription: "Dog")
    private var cancellables = Set<AnyCancellable>()
    
    @Test
    func textWithoutGlyphsIsLeftAlone() {
        #expect(StickerGlyphText.classify([]) == .none)
        #expect(StickerGlyphText.classify([.text("Olá")]) == .none)
        #expect(StickerGlyphText.segments(of: NSAttributedString(string: "Olá")) == [.text("Olá")])
    }
    
    @Test
    func aLoneGlyphIsSentAtOnce() {
        #expect(StickerGlyphText.classify([.glyph(cat)]) == .single(cat))
        #expect(StickerGlyphText.classify([.text(" "), .glyph(cat), .text("\n")]) == .single(cat))
    }
    
    @Test
    func glyphsAmongTextFollowTheTextInOrder() {
        #expect(StickerGlyphText.classify([.text("Bom "), .glyph(cat), .text("dia"), .glyph(dog)]) == .mixed(text: "Bom dia", glyphs: [cat, dog]))
        #expect(StickerGlyphText.classify([.glyph(cat), .glyph(dog)]) == .mixed(text: "", glyphs: [cat, dog]))
    }
    
    @Test
    func pastedStickersLeaveTheComposerAsStickers() async throws {
        let viewModel = makeComposer()
        var actions: [ComposerToolbarViewModelAction] = []
        viewModel.actions.sink { actions.append($0) }.store(in: &cancellables)
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        
        viewModel.process(viewAction: .handlePasteOrDrop(providers: [NSItemProvider(item: data as NSData, typeIdentifier: "com.apple.png-sticker")]))
        try await waitUntil { pastedSticker(in: actions) != nil }
        
        #expect(pastedSticker(in: actions) == data)
        #expect(!containsPaste(actions))
    }
    
    @Test
    func otherPastesKeepTheirBehaviour() {
        let viewModel = makeComposer()
        var actions: [ComposerToolbarViewModelAction] = []
        viewModel.actions.sink { actions.append($0) }.store(in: &cancellables)
        
        viewModel.process(viewAction: .handlePasteOrDrop(providers: [NSItemProvider(item: "Hello" as NSString, typeIdentifier: "public.plain-text")]))
        
        #expect(containsPaste(actions))
    }
    
    private func pastedSticker(in actions: [ComposerToolbarViewModelAction]) -> Data? {
        for case .sendPastedSticker(let data) in actions {
            return data
        }
        return nil
    }
    
    private func containsPaste(_ actions: [ComposerToolbarViewModelAction]) -> Bool {
        for case .handlePasteOrDrop in actions {
            return true
        }
        return false
    }
    
    private func makeComposer() -> ComposerToolbarViewModel {
        let viewModel = ComposerToolbarViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                                 wysiwygViewModel: WysiwygComposerViewModel(),
                                                 completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init()),
                                                 mediaProvider: MediaProviderMock(.init()),
                                                 mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                                 userSettings: UserSettings.mock(),
                                                 analyticsService: AnalyticsServiceMock(.init()),
                                                 composerDraftService: ComposerDraftServiceMock(.init()))
        viewModel.context.composerFormattingEnabled = false
        return viewModel
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
