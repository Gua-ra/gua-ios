//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import Foundation
import ImageIO
import Testing

@MainActor
final class StickerEditorScreenViewModelTests {
    private var appSettings = AppSettings.volatile()
    private var saved: [SavedSticker] = []
    private var saveResult: Result<Void, StickerEditorError> = .success(())
    private var cancellables = Set<AnyCancellable>()
    
    @Test
    func imageAspectFitsTheCanvasThenFollowsTheFraming() {
        let size = CGSize(width: 600, height: 400)
        
        #expect(StickerCanvas.imageRect(imageSize: size, scale: 1, offset: .zero).integral == CGRect(x: 0, y: 85, width: 512, height: 342))
        #expect(StickerCanvas.imageRect(imageSize: size, scale: 2, offset: CGSize(width: 10, height: -20)).integral == CGRect(x: -246, y: -106, width: 1024, height: 684))
        
        let point = StickerCanvas.imagePoint(forCanvasPoint: CGPoint(x: 256, y: 256), imageSize: size, scale: 1, offset: .zero)
        #expect(point.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) } == CGPoint(x: 300, y: 200))
        #expect(StickerCanvas.imagePoint(forCanvasPoint: CGPoint(x: 256, y: 10), imageSize: size, scale: 1, offset: .zero) == nil)
    }
    
    @Test
    func captionsAreDrawnWhole() throws {
        let blank = try Self.image(width: 8, height: 8, gray: false) { $0.clear(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let sticker = try #require(StickerCanvas.render(blank, outlined: false, scale: 1, offset: .zero, text: "HH"))
        
        // Heavy 64 pt capitals stand about 45 px tall, all of it above the baseline.
        #expect(try Self.opaqueRows(of: sticker).count > 40)
    }
    
    @Test
    func outputIsTheFramedPhotoTrimmedAndPadded() throws {
        let viewModel = makeViewModel()
        
        let file = try #require(viewModel.makeStickerFile())
        #expect(file.pixelWidth == 512)
        #expect((350...354).contains(file.pixelHeight))
        
        viewModel.context.send(viewAction: .setFraming(scale: 2, offset: .zero))
        let zoomed = try #require(viewModel.makeStickerFile())
        #expect(zoomed.pixelWidth == 512)
        #expect(zoomed.pixelHeight == 512)
    }
    
    @Test
    func theCutOutKeepsOnlyTheChosenSubjects() async throws {
        let cutout = try Self.cutout()
        let viewModel = makeViewModel(cutout: cutout)
        try await waitUntil { !viewModel.state.isFindingSubjects }
        
        #expect(viewModel.state.isCutOutEnabled)
        #expect(viewModel.state.selectedSubjects == [0, 1])
        
        // The left subject sits at the left of the photo, which aspect-fits the canvas.
        viewModel.context.send(viewAction: .tapCanvas(CGPoint(x: 20, y: 256)))
        #expect(viewModel.state.selectedSubjects == [1])
        
        let file = try #require(viewModel.makeStickerFile())
        let decoded = try #require(CGImageSourceCreateWithData(file.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // Only the right half's subject, as tall as it is wide, is left.
        #expect(decoded.width < decoded.height)
        
        viewModel.context.send(viewAction: .setCutOut(false))
        #expect(!viewModel.state.isCutOutEnabled)
    }
    
    @Test
    func sendPassesTheTextAsTheBodyAndDismisses() async throws {
        let viewModel = makeViewModel()
        var dismissed = false
        viewModel.actions.sink { _ in dismissed = true }.store(in: &cancellables)
        
        viewModel.context.send(viewAction: .setText("  Bom dia "))
        viewModel.context.send(viewAction: .send)
        try await waitUntil { dismissed }
        
        #expect(saved.map(\.body) == ["Bom dia"])
        #expect(saved.map(\.send) == [true])
        #expect(appSettings.guaStickerCreatorNoteShown)
    }
    
    @Test
    func saveWithoutTextUsesStickerAsTheBody() async throws {
        let viewModel = makeViewModel()
        
        viewModel.context.send(viewAction: .save)
        try await waitUntil { !self.saved.isEmpty }
        
        #expect(saved.map(\.body) == ["Sticker"])
        #expect(saved.map(\.send) == [false])
    }
    
    @Test
    func theLimitIsShownAndTheEditorStays() async throws {
        saveResult = .failure(.limitReached)
        let viewModel = makeViewModel()
        
        viewModel.context.send(viewAction: .save)
        try await waitUntil { viewModel.state.bindings.alertInfo != nil }
        
        #expect(viewModel.state.bindings.alertInfo?.id == .limitReached)
        #expect(!appSettings.guaStickerCreatorNoteShown)
        #expect(viewModel.state.showsNote)
    }
    
    @Test
    func theNoteIsOnlyShownTheFirstTime() {
        appSettings.guaStickerCreatorNoteShown = true
        
        #expect(!makeViewModel().state.showsNote)
    }
    
    private func makeViewModel(cutout: StickerCutout? = nil) -> StickerEditorScreenViewModel {
        let cutoutService = StickerCutoutServiceMock()
        cutoutService.cutoutOfReturnValue = cutout
        return StickerEditorScreenViewModel(photo: cutout?.image ?? StickerPreviewImages.photo, cutoutService: cutoutService, appSettings: appSettings) { [weak self] file, body, send in
            self?.saved.append(SavedSticker(file: file, body: body, send: send))
            return self?.saveResult ?? .failure(.failed)
        }
    }
    
    /// A 512 × 256 photo with one subject on each half.
    private static func cutout() throws -> StickerCutout {
        let photo = try image(width: 512, height: 256, gray: false) { context in
            context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        }
        let left = try image(width: 512, height: 256, gray: true) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 16, y: 16, width: 200, height: 224))
        }
        let right = try image(width: 512, height: 256, gray: true) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 320, y: 16, width: 100, height: 224))
        }
        return StickerCutout(image: photo, subjectMasks: [left, right])
    }
    
    private static func image(width: Int, height: Int, gray: Bool, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil,
                                             width: width,
                                             height: height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: 0,
                                             space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }
    
    private static func opaqueRows(of image: CGImage) throws -> [Int] {
        let context = try #require(CGContext(data: nil,
                                             width: image.width,
                                             height: image.height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).filter { row in
            (0..<image.width).contains { column in pixels[(row * image.width + column) * 4 + 3] > 127 }
        }
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private struct SavedSticker {
    let file: StickerFile
    let body: String
    let send: Bool
}
