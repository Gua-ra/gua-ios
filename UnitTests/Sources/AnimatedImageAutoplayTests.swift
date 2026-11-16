//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Kingfisher
import SwiftUI
import Testing

@MainActor
final class AnimatedImageAutoplayTests {
    private let gifFile = ExpressionPanelPreviewFixtures.gifItems[0].preview?.animated
    private let gifProvider = ExpressionPanelPreviewFixtures.gifPreviewViewModel().context.viewState.gifProvider
    
    // The system's Auto-Play Animated Images stays the same while these run, so one of the two cases differs from it.
    @Test(arguments: [true, false])
    func firstFrameFollowsTheSetting(isOn: Bool) throws {
        let appSettings = AppSettings.volatile()
        appSettings.guaPlayGifsAutomatically = isOn
        let probe = AutoplayProbe()
        
        let window = try host(probe.playsAnimatedImages(following: appSettings))
        defer { window.isHidden = true }
        
        #expect(probe.recorder.values.first == isOn)
        #expect(probe.recorder.values.allSatisfy { $0 == isOn })
    }
    
    @Test
    func withoutAppSettingsGIFsKeepPlaying() throws {
        let probe = AutoplayProbe()
        
        let window = try host(probe.playsAnimatedImages(following: nil))
        defer { window.isHidden = true }
        
        #expect(!probe.recorder.values.isEmpty)
        #expect(probe.recorder.values.allSatisfy { $0 })
    }
    
    @Test
    func changingTheSettingReachesShownViews() async throws {
        let appSettings = AppSettings.volatile()
        let probe = AutoplayProbe()
        let window = try host(probe.playsAnimatedImages(following: appSettings))
        defer { window.isHidden = true }
        
        appSettings.guaPlayGifsAutomatically = false
        try await waitUntil(window) { probe.recorder.values.last == false }
        
        appSettings.guaPlayGifsAutomatically = true
        try await waitUntil(window) { probe.recorder.values.last == true }
    }
    
    @Test(arguments: [true, false])
    func gridTileFollowsTheSetting(isOn: Bool) async throws {
        let file = try #require(gifFile)
        let window = try host(GifImage(file: file, provider: gifProvider)
            .environment(\.playsAnimatedImages, isOn))
        defer { window.isHidden = true }
        
        let imageView = try await animatedImageView(in: window)
        #expect(imageView.autoPlayAnimatedImage == isOn)
    }
    
    @Test
    func previewSheetPlaysWithTheSettingOff() async throws {
        let viewModel = ExpressionPanelPreviewFixtures.gifPreviewViewModel()
        let window = try host(GifPreviewSheet(context: viewModel.context)
            .environment(\.playsAnimatedImages, false))
        defer { window.isHidden = true }
        
        let imageView = try await animatedImageView(in: window)
        #expect(imageView.autoPlayAnimatedImage)
    }
    
    @Test
    func timelineGifFollowsTheSetting() async throws {
        let still = AutoplayProbe.Recorder()
        let stillWindow = try host(timelineGif(named: "still", rendered: still)
            .environment(\.playsAnimatedImages, false))
        defer { stillWindow.isHidden = true }
        let playingWindow = try host(timelineGif(named: "playing", rendered: AutoplayProbe.Recorder())
            .environment(\.playsAnimatedImages, true))
        defer { playingWindow.isHidden = true }
        
        _ = try await animatedImageView(in: playingWindow)
        try await waitUntil(stillWindow) { !still.values.isEmpty }
        // The still GIF started loading first, so by now it would be animating if the setting were ignored.
        #expect(animatedImageViews(in: stillWindow).isEmpty)
    }
    
    @Test(arguments: [true, false])
    func gifBadgeShowsOnlyWhenTheSettingIsOff(isOn: Bool) {
        let controller = UIHostingController(rootView: AnimatedImageBadge().environment(\.playsAnimatedImages, isOn))
        
        let size = controller.sizeThatFits(in: CGSize(width: 200, height: 200))
        
        #expect((size == .zero) == isOn)
    }
    
    // MARK: - Helpers
    
    private func timelineGif(named name: String, rendered: AutoplayProbe.Recorder) throws -> some View {
        let data = StickerPreviewImages.pngData(0)
        let mediaProvider = MediaProviderMock(.init())
        mediaProvider.imageFromSourceSizeClosure = { _, _ in nil }
        mediaProvider.loadImageDataFromSourceClosure = { _ in .success(data) }
        let mediaSource = try MediaSourceProxy(url: #require(URL(string: "mxc://gua.test/\(name)")), mimeType: "image/gif")
        
        return LoadableImage(mediaSource: mediaSource, isAnimated: true, mediaProvider: mediaProvider) { image in
            rendered.values.append(true)
            return image
        } placeholder: {
            Color.clear
        }
        .frame(width: 100, height: 100)
    }
    
    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }
    
    private func waitUntil(_ window: UIWindow, _ condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 100 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
        #expect(condition())
    }
    
    private func animatedImageView(in window: UIWindow) async throws -> AnimatedImageView {
        var imageViews = animatedImageViews(in: window)
        try await waitUntil(window) {
            imageViews = animatedImageViews(in: window)
            return !imageViews.isEmpty
        }
        return try #require(imageViews.first)
    }
    
    private func animatedImageViews(in view: UIView) -> [AnimatedImageView] {
        let nested = view.subviews.flatMap(animatedImageViews)
        guard let imageView = view as? AnimatedImageView else { return nested }
        return [imageView] + nested
    }
}

private struct AutoplayProbe: View {
    @Environment(\.playsAnimatedImages) private var playsAnimatedImages
    
    let recorder = Recorder()
    
    var body: some View {
        recorder.values.append(playsAnimatedImages)
        return Color.clear
    }
    
    final class Recorder {
        var values: [Bool] = []
    }
}
