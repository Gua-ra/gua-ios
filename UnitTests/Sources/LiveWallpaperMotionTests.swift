//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import SwiftUI
import Testing

final class LiveWallpaperMotionTests {
    // MARK: - Policy
    
    @Test
    func animatesWhenNothingStopsIt() {
        let policy = WallpaperMotionPolicy()
        #expect(policy.motion == .animating)
        #expect(policy.animates)
    }
    
    @Test
    func pausesWhenTheChatIsNotOnScreen() {
        #expect(WallpaperMotionPolicy(isOnScreen: false).motion == .paused)
    }
    
    @Test
    func pausesInTheBackgroundAndWithTheScreenOff() {
        #expect(WallpaperMotionPolicy(isAppActive: false).motion == .paused)
    }
    
    @Test
    func pausesUnderASheetOrTheMessageMenu() {
        #expect(WallpaperMotionPolicy(isCovered: true).motion == .paused)
    }
    
    @Test
    func staysStillWithReduceMotion() {
        #expect(WallpaperMotionPolicy(reducesMotion: true).motion == .still)
    }
    
    @Test
    func staysStillInLowPowerMode() {
        #expect(WallpaperMotionPolicy(isLowPowerModeEnabled: true).motion == .still)
    }
    
    @Test(arguments: [(ProcessInfo.ThermalState.nominal, true), (.fair, true), (.serious, false), (.critical, false)])
    func staysStillWhenTheDeviceIsHot(thermalState: ProcessInfo.ThermalState, animates: Bool) {
        let policy = WallpaperMotionPolicy(thermalState: thermalState)
        #expect(policy.animates == animates)
        #expect(policy.motion == (animates ? .animating : .still))
    }
    
    @Test
    func staysStillAfterSlowFrames() {
        #expect(WallpaperMotionPolicy(hasSlowFrames: true).motion == .still)
    }
    
    @Test
    func staysStillWithoutARenderer() {
        #expect(WallpaperMotionPolicy(isRendererAvailable: false).motion == .still)
    }
    
    @Test
    func stillWinsOverPaused() {
        let policy = WallpaperMotionPolicy(isOnScreen: false, isAppActive: false, isCovered: true, reducesMotion: true)
        #expect(policy.motion == .still)
        #expect(!policy.animates)
    }
    
    @Test
    func theViewAddsWhatOnlyItCanSee() {
        let policy = WallpaperMotionPolicy()
        #expect(policy.including(isInWindow: true, isSceneActive: true, isCovered: false).motion == .animating)
        #expect(policy.including(isInWindow: false, isSceneActive: true, isCovered: false).motion == .paused)
        #expect(policy.including(isInWindow: true, isSceneActive: false, isCovered: false).motion == .paused)
        // A presentation, or a hidden window under the app lock screen.
        #expect(policy.including(isInWindow: true, isSceneActive: true, isCovered: true).motion == .paused)
    }
    
    @Test
    func theViewNeverClearsWhatSwiftUISaw() {
        let fullScreenCall = WallpaperMotionPolicy(isCovered: true)
        #expect(fullScreenCall.including(isInWindow: true, isSceneActive: true, isCovered: false).motion == .paused)
        
        let offScreen = WallpaperMotionPolicy(isOnScreen: false)
        #expect(offScreen.including(isInWindow: true, isSceneActive: true, isCovered: false).motion == .paused)
        
        let reducedMotion = WallpaperMotionPolicy(reducesMotion: true)
        #expect(reducedMotion.including(isInWindow: true, isSceneActive: true, isCovered: false).motion == .still)
    }
    
    @Test
    func slowFramesKeepEveryWallpaperStillForTheSession() {
        let conditions = LiveWallpaperConditions()
        let policy = conditions.policy(for: .silk, isOnScreen: true, reducesMotion: false)
        #expect(policy.isLowPowerModeEnabled == ProcessInfo.processInfo.isLowPowerModeEnabled)
        #expect(policy.thermalState == ProcessInfo.processInfo.thermalState)
        #expect(!policy.hasSlowFrames)
        
        conditions.reportSlowFrames()
        
        #expect(conditions.policy(for: .silk, isOnScreen: true, reducesMotion: false).motion == .still)
        #expect(conditions.policy(for: .ipe, isOnScreen: false, reducesMotion: false).motion == .still)
    }
    
    @Test
    func aShaderThatFailsKeepsOnlyItsArtworkStill() {
        let conditions = LiveWallpaperConditions()
        #expect(conditions.policy(for: .silk, isOnScreen: true, reducesMotion: false).isRendererAvailable)
        
        conditions.reportUnavailable(.silk)
        
        #expect(conditions.policy(for: .silk, isOnScreen: true, reducesMotion: false).motion == .still)
        #expect(conditions.policy(for: .ipe, isOnScreen: true, reducesMotion: false).isRendererAvailable)
    }
    
    @Test
    func aFullScreenCallCoversTheChat() {
        let conditions = LiveWallpaperConditions()
        let policy = conditions.policy(for: .silk, isOnScreen: true, isCovered: true, reducesMotion: false)
        #expect(policy.isCovered)
        #expect(policy.motion != .animating)
    }
    
    @Test
    func snapshotsAndPreviewsShowTheStill() {
        #expect(!ChatLiveWallpaperView.isEnabled)
        #expect(!ChatLiveWallpaperView.isShown(for: .glassDrops, sendPulse: ChatWallpaperSendPulse()))
        #expect(!ChatLiveWallpaperView.canAnimate(.glassDrops, reducesMotion: false))
    }
    
    @Test
    func onlyTheChatAndThePreviewGetTheRenderer() {
        #expect(ChatLiveWallpaperView.isShown(for: .glassDrops, sendPulse: ChatWallpaperSendPulse(), isEnabled: true))
        // Theme tiles, the header and the wallpaper picker set no send pulse.
        #expect(!ChatLiveWallpaperView.isShown(for: .glassDrops, sendPulse: nil, isEnabled: true))
        #expect(!ChatLiveWallpaperView.isShown(for: .palmCoast, sendPulse: ChatWallpaperSendPulse(), isEnabled: true))
    }
    
    @Test
    func thePreviewOffersASendOnlyWhenTheWallpaperCanMove() {
        #expect(!ChatLiveWallpaperView.canAnimate(.glassDrops, reducesMotion: true, isEnabled: true))
        #expect(!ChatLiveWallpaperView.canAnimate(.palmCoast, reducesMotion: false, isEnabled: true))
    }
    
    // MARK: - Frame watchdog
    
    @Test
    func watchdogAcceptsSteadyFrames() {
        var watchdog = WallpaperFrameWatchdog()
        let tripped = drawFrames(into: &watchdog, every: 1.0 / 30, taking: 0.008, from: 0, for: 10)
        #expect(!tripped)
    }
    
    @Test
    func watchdogLimitIsFiftyFourMilliseconds() {
        #expect(abs(WallpaperFrameWatchdog.limit - 0.054) < 1e-9)
    }
    
    @Test
    func watchdogJudgesOnceTheWindowHoldsTenFrames() {
        var watchdog = WallpaperFrameWatchdog()
        let trippedEarly = drawFrames(into: &watchdog, count: 9, every: 0.06, taking: 0.06, from: 0)
        let tripped = watchdog.recordFrame(duration: 0.06, endingAt: 0.6)
        #expect(!trippedEarly)
        #expect(tripped)
        #expect(watchdog.hasTripped)
    }
    
    @Test(arguments: [(0.053999, false), (0.054, false), (0.054001, true)])
    func watchdogTripsOnlyOverTheLimit(gpuTime: TimeInterval, trips: Bool) {
        var watchdog = WallpaperFrameWatchdog()
        let tripped = drawFrames(into: &watchdog, count: 120, every: gpuTime, taking: gpuTime, from: 0)
        #expect(tripped == trips)
    }
    
    @Test
    func watchdogForgetsFramesOlderThanTwoSeconds() {
        var watchdog = WallpaperFrameWatchdog()
        let trippedBySlowFrames = drawFrames(into: &watchdog, count: 9, every: 0.06, taking: 0.06, from: 0)
        // The slow frames ended over 2 s before these, so the window holds only fast ones.
        let trippedLater = drawFrames(into: &watchdog, count: 60, every: 1.0 / 30, taking: 0.008, from: 2.6)
        #expect(!trippedBySlowFrames)
        #expect(!trippedLater)
    }
    
    @Test
    func watchdogIgnoresAFewHitches() {
        var watchdog = WallpaperFrameWatchdog()
        var time = 0.0
        var tripped = false
        // One frame in 20 takes 400 ms: the 90th percentile stays on budget.
        for frame in 0..<400 {
            let duration = frame % 20 == 19 ? 0.4 : 0.01
            time += max(duration, 1.0 / 30)
            tripped = watchdog.recordFrame(duration: duration, endingAt: time) || tripped
        }
        #expect(!tripped)
    }
    
    @Test
    func watchdogTripsWhenOneFrameInSevenIsSlow() {
        var watchdog = WallpaperFrameWatchdog()
        var time = 0.0
        var tripped = false
        for frame in 0..<200 {
            let duration = frame % 7 == 6 ? 0.07 : 0.01
            time += max(duration, 1.0 / 30)
            tripped = watchdog.recordFrame(duration: duration, endingAt: time) || tripped
        }
        #expect(tripped)
    }
    
    @Test
    func watchdogIgnoresAStallBetweenFrames() {
        var watchdog = WallpaperFrameWatchdog()
        // The main thread stalls for 1.8 s: frames stop, but none of them is slow.
        let trippedBefore = drawFrames(into: &watchdog, every: 1.0 / 30, taking: 0.008, from: 0, for: 5)
        let trippedAfter = drawFrames(into: &watchdog, every: 1.0 / 30, taking: 0.008, from: 6.8, for: 5)
        #expect(!trippedBefore)
        #expect(!trippedAfter)
    }
    
    @Test
    func watchdogIgnoresOneStrayFrame() {
        var watchdog = WallpaperFrameWatchdog()
        // One frame held up on the GPU for 1.8 s among steady ones never decides the percentile alone.
        var tripped = drawFrames(into: &watchdog, every: 1.0 / 30, taking: 0.008, from: 0, for: 5)
        tripped = watchdog.recordFrame(duration: 1.8, endingAt: 6.8) || tripped
        tripped = drawFrames(into: &watchdog, every: 1.0 / 30, taking: 0.008, from: 6.83, for: 5) || tripped
        #expect(!tripped)
    }
    
    @Test
    func watchdogStartsOverAfterAPause() {
        var watchdog = WallpaperFrameWatchdog()
        let trippedBefore = drawFrames(into: &watchdog, count: 9, every: 0.06, taking: 0.06, from: 0)
        
        watchdog.restart()
        // The slow frames before the pause no longer count towards the ten.
        let trippedAfter = drawFrames(into: &watchdog, count: 9, every: 0.06, taking: 0.06, from: 0.6)
        let trippedLater = watchdog.recordFrame(duration: 0.06, endingAt: 1.2)
        #expect(!trippedBefore)
        #expect(!trippedAfter)
        #expect(trippedLater)
    }
    
    @Test
    func watchdogStaysTripped() {
        var watchdog = WallpaperFrameWatchdog()
        let tripped = drawFrames(into: &watchdog, every: 0.1, taking: 0.1, from: 0, for: 3)
        let trippedByAFastFrame = watchdog.recordFrame(duration: 0.001, endingAt: 10)
        watchdog.restart()
        let trippedAfterARestart = drawFrames(into: &watchdog, every: 1.0 / 30, taking: 0.008, from: 20, for: 1)
        #expect(tripped)
        #expect(trippedByAFastFrame)
        #expect(trippedAfterARestart)
    }
    
    // MARK: - Layout and uniforms
    
    @Test
    func aPhoneChatDrawsTheWholeStillAtHalfItsPixels() throws {
        // An iPhone 17 Pro chat below the navigation bar, at 3x.
        let viewSize = CGSize(width: 402, height: 758)
        let layout = LiveWallpaperLayout(artwork: .glassDrops, viewSize: viewSize, displayScale: 3)
        
        #expect(abs(layout.rect.width / layout.rect.height - ChatArtwork.pixelSize.width / ChatArtwork.pixelSize.height) < 0.001)
        #expect(layout.rect.width == viewSize.width)
        #expect(layout.drawableSize == CGSize(width: (layout.rect.width * 1.5).rounded(), height: (layout.rect.height * 1.5).rounded()))
        
        let scissor = try #require(layout.scissor)
        #expect(scissor.width >= viewSize.width * 1.5 && scissor.height >= viewSize.height * 1.5)
        #expect(scissor.minX >= 0 && scissor.minY >= 0)
        #expect(scissor.maxX <= layout.drawableSize.width && scissor.maxY <= layout.drawableSize.height)
    }
    
    @Test
    func aWideChatGetsAFewerPixelDrawable() {
        // An iPhone in landscape: the still's rect is over five times the chat.
        let viewSize = CGSize(width: 874, height: 340)
        let layout = LiveWallpaperLayout(artwork: .silk, viewSize: viewSize, displayScale: 3)
        let visiblePixels = viewSize.width * viewSize.height * 1.5 * 1.5
        
        #expect(layout.rect.width == viewSize.width)
        #expect(layout.drawableSize.width * layout.drawableSize.height <= LiveWallpaperLayout.maximumAreaRatio * visiblePixels * 1.01)
        #expect(abs(layout.drawableSize.width / layout.drawableSize.height - layout.rect.width / layout.rect.height) < 0.01)
    }
    
    // An iPhone 17 Pro chat is 402 by 758 points from the navigation bar down to the bottom of the screen, behind a
    // 34-point home indicator, a 64-point composer and a 336-point keyboard; composer tops below are what those leave.
    
    @Test(arguments: [(CGSize(width: 402, height: 758), 0...660),
                      (CGSize(width: 402, height: 758), 0...358),
                      (CGSize(width: 874, height: 340), 0...255),
                      (CGSize(width: 820, height: 1106), 0...1022),
                      (CGSize(width: 1376, height: 950), 0...886),
                      // A canvas reaching up under a 116-point top bar.
                      (CGSize(width: 402, height: 874), 116...776)] as [(CGSize, ClosedRange<CGFloat>)])
    func thePulseSpotIsTheShadersSpotOnTheVisibleChat(canvasSize: CGSize, visibleChat: ClosedRange<CGFloat>) {
        for artwork in ChatArtwork.allCases where artwork.isLive {
            let layout = LiveWallpaperLayout(artwork: artwork, viewSize: canvasSize, displayScale: 3)
            let spot = spotInCanvas(layout.pulseOrigin(visibleTop: visibleChat.lowerBound, visibleBottom: visibleChat.upperBound), of: layout)
            
            #expect(abs(spot.x - canvasSize.width * 0.83) < 0.5, "\(artwork.id) \(canvasSize)")
            #expect(abs(visibleChat.upperBound - spot.y - (visibleChat.upperBound - visibleChat.lowerBound) * 0.113) < 0.5, "\(artwork.id) \(canvasSize)")
        }
    }
    
    @Test
    func thePulseSpotFollowsTheKeyboardWithoutMovingTheFrame() {
        let layout = LiveWallpaperLayout(artwork: .glassDrops, viewSize: CGSize(width: 402, height: 758), displayScale: 3)
        let keyboardClosed = frame(in: layout, visibleBottom: 660)
        let keyboardOpen = frame(in: layout, visibleBottom: 358)
        
        #expect(keyboardOpen.res == keyboardClosed.res)
        #expect(keyboardOpen.origin.x == keyboardClosed.origin.x)
        #expect(keyboardOpen.origin.y > keyboardClosed.origin.y)
        #expect(spotInCanvas(keyboardClosed.origin, of: layout).y < 660)
        #expect(spotInCanvas(keyboardOpen.origin, of: layout).y < 358)
    }
    
    @Test
    func aTallerComposerRaisesTheSpot() {
        let layout = LiveWallpaperLayout(artwork: .silk, viewSize: CGSize(width: 402, height: 758), displayScale: 3)
        let oneLine = layout.pulseOrigin(visibleTop: 0, visibleBottom: 660)
        let fourLines = layout.pulseOrigin(visibleTop: 0, visibleBottom: 584)
        
        #expect(fourLines.y > oneLine.y)
        #expect(fourLines.x == oneLine.x)
        #expect(abs(584 - spotInCanvas(fourLines, of: layout).y - 584 * 0.113) < 0.5)
    }
    
    // The same chat in SwiftUI's global space: its canvas starts 116 points down, below the top bar, and the composer
    // and the keyboard are measured there too.
    
    @Test(arguments: [(776, 660), (474, 358), (60, -56), (930, 814)] as [(CGFloat, CGFloat)])
    func theComposerIsMeasuredFromTheCanvasTop(composerGlobalTop: CGFloat, visibleBottom: CGFloat) {
        let chat = visibleChat(composerGlobalTop: composerGlobalTop)
        #expect(chat.top == 0)
        #expect(chat.bottom == visibleBottom)
    }
    
    @Test
    func aComposerOutsideTheCanvasPutsTheSpotOnItsEdge() {
        let layout = LiveWallpaperLayout(artwork: .glassDrops, viewSize: CGSize(width: 402, height: 758), displayScale: 3)
        
        let above = visibleChat(composerGlobalTop: 60)
        let spotAbove = spotInCanvas(layout.pulseOrigin(visibleTop: above.top, visibleBottom: above.bottom), of: layout)
        #expect(abs(spotAbove.y) < 0.5)
        
        let below = visibleChat(composerGlobalTop: 930)
        let spotBelow = spotInCanvas(layout.pulseOrigin(visibleTop: below.top, visibleBottom: below.bottom), of: layout)
        #expect(abs(758 - spotBelow.y - 758 * 0.113) < 0.5)
    }
    
    @Test
    func aCanvasUnderTheTopBarStartsTheChatBelowIt() {
        let chat = LiveWallpaperLayout.visibleChat(canvasHeight: 874,
                                                   canvasGlobalTop: 0,
                                                   composerGlobalTop: 776,
                                                   topInset: 116,
                                                   bottomInset: 34,
                                                   windowBottomInset: 34)
        #expect(chat.top == 116)
        #expect(chat.bottom == 776)
    }
    
    @Test
    func withoutAComposerTheChatEndsAboveTheHomeIndicator() {
        #expect(visibleChat(canvasGlobalTop: nil, composerGlobalTop: nil).bottom == 724)
        #expect(visibleChat(canvasGlobalTop: nil, composerGlobalTop: 776).bottom == 724)
        #expect(visibleChat(composerGlobalTop: nil).bottom == 724)
        // The canvas's own inset also holds the keyboard, which the window's never does.
        #expect(visibleChat(composerGlobalTop: nil, bottomInset: 370).bottom == 724)
        #expect(visibleChat(composerGlobalTop: nil, bottomInset: 0).bottom == 758)
        #expect(visibleChat(composerGlobalTop: nil, windowBottomInset: nil).bottom == 758)
        #expect(visibleChat(composerGlobalTop: nil).top == 0)
        
        let layout = LiveWallpaperLayout(artwork: .ipe, viewSize: CGSize(width: 402, height: 758), displayScale: 3)
        let spot = spotInCanvas(layout.pulseOrigin(visibleTop: 0, visibleBottom: 724), of: layout)
        #expect(abs(724 - spot.y - 724 * 0.113) < 0.5)
    }
    
    @Test
    func theRoomScreenReportsItsComposerTop() async throws {
        let room = makeRoom()
        let roomScreen = RoomScreenViewModel.mock(roomProxyMock: JoinedRoomProxyMock(.init(id: room.viewModel.context.viewState.roomID, name: "Live wallpaper")))
        let composer = ComposerToolbarViewModel.mock()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ElementNavigationStack {
            RoomScreen(context: roomScreen.context, timelineContext: room.viewModel.context, composerToolbar: ComposerToolbar(context: composer.context))
        })
        window.isHidden = false
        defer { window.isHidden = true }
        
        var waits = 0
        while room.pulse.composerTop == nil, waits < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waits += 1
        }
        
        let composerTop = try #require(room.pulse.composerTop)
        #expect(composerTop > window.bounds.height / 2)
        #expect(composerTop < window.bounds.height - window.safeAreaInsets.bottom)
    }
    
    @Test
    func thePreviewSpotIsAboveItsControls() {
        // The full-screen theme preview below its Cancel bar, with Light/Dark and Set theme above the home indicator.
        let canvasSize = CGSize(width: 402, height: 758)
        let controlsTop: CGFloat = 598
        for artwork in ChatArtwork.allCases where artwork.isLive {
            let layout = LiveWallpaperLayout(artwork: artwork, viewSize: canvasSize, displayScale: 3)
            let spot = spotInCanvas(layout.pulseOrigin(visibleTop: 0, visibleBottom: controlsTop), of: layout)
            
            #expect(spot.y > 0 && spot.y < controlsTop, "\(artwork.id)")
            #expect(abs(controlsTop - spot.y - controlsTop * 0.113) < 0.5, "\(artwork.id)")
        }
    }
    
    @Test
    func aCanvasShapedLikeTheStillKeepsTheSpotInTheVisibleChat() {
        // An iPhone 17 Pro Max chat whose canvas is the still's own shape, so the frame is the canvas.
        let canvasSize = CGSize(width: 430, height: 932)
        let layout = LiveWallpaperLayout(artwork: .glassDrops, viewSize: canvasSize, displayScale: 3)
        let shadersOwnOrigin = SIMD2(Float(layout.drawableSize.width) * 0.83, Float(layout.drawableSize.height) * 0.113)
        #expect(abs(layout.rect.minX) < 0.01 && abs(layout.rect.minY) < 0.01 && abs(layout.rect.height - canvasSize.height) < 0.01)
        
        for composerTop: CGFloat in [834, 532] {
            let spot = spotInCanvas(layout.pulseOrigin(visibleTop: 0, visibleBottom: composerTop), of: layout)
            #expect(spot.x > 0 && spot.x < canvasSize.width, "\(composerTop)")
            #expect(spot.y > 0 && spot.y < composerTop, "\(composerTop)")
        }
        // With the keyboard open, the shaders' own spot would be behind it.
        #expect(spotInCanvas(shadersOwnOrigin, of: layout).y > 532)
    }
    
    @Test
    func uniformsComeFromTheLayoutAndTheMotion() {
        let layout = LiveWallpaperLayout(artwork: .ipe, viewSize: CGSize(width: 402, height: 758), displayScale: 3)
        let origin = layout.pulseOrigin(visibleTop: 0, visibleBottom: 660)
        
        let animating = LiveWallpaperUniforms.frame(in: layout, origin: origin, isDark: true, time: 25.5, pulse: 0.6, animates: true)
        #expect(animating.res == SIMD2(Float(layout.drawableSize.width), Float(layout.drawableSize.height)))
        #expect(animating.origin == origin)
        #expect(animating.tilt == .zero)
        #expect(animating.time == 25.5)
        #expect(animating.dark == 1)
        #expect(animating.pulse == 0.6)
        
        let held = LiveWallpaperUniforms.frame(in: layout, origin: origin, isDark: false, time: 25.5, pulse: 0.6, animates: false)
        #expect(held.dark == 0)
        #expect(held.pulse == 0)
        #expect(held.time == 25.5)
    }
    
    // MARK: - Time
    
    @Test
    func timeStartsAtTheStill() {
        let clock = LiveWallpaperClock(stillTime: 24)
        #expect(clock.time(at: 1000) == 24)
        #expect(!clock.isRunning)
    }
    
    @Test
    func timeAdvancesWhileRunning() {
        var clock = LiveWallpaperClock(stillTime: 24)
        clock.start(at: 100)
        #expect(clock.isRunning)
        #expect(clock.time(at: 100) == 24)
        #expect(clock.time(at: 101.5) == 25.5)
        
        clock.start(at: 101)
        #expect(clock.time(at: 103) == 27)
    }
    
    @Test
    func pauseAndResumeKeepTheTime() {
        var clock = LiveWallpaperClock(stillTime: 14)
        clock.start(at: 100)
        clock.pause(at: 103)
        #expect(!clock.isRunning)
        #expect(clock.time(at: 103) == 17)
        #expect(clock.time(at: 500) == 17)
        
        clock.pause(at: 600)
        #expect(clock.time(at: 600) == 17)
        
        clock.start(at: 700)
        #expect(clock.time(at: 700) == 17)
        #expect(clock.time(at: 702) == 19)
    }
    
    @Test
    func timeWrapsEveryHalfHour() {
        var clock = LiveWallpaperClock(stillTime: 48)
        clock.start(at: 0)
        #expect(clock.time(at: 1751) == 1799)
        #expect(clock.time(at: 1752) == 0)
        #expect(clock.time(at: 1760) == 8)
        // A week in, the time still has millisecond precision.
        #expect(abs(clock.time(at: 7 * 86400 + 0.25) - 48.25) < 0.001)
    }
    
    // MARK: - Send pulse
    
    @Test
    func pulseFollowsTheLabEnvelope() {
        #expect(LiveWallpaperPulse.value(secondsSinceSend: -0.1) == 0)
        #expect(LiveWallpaperPulse.value(secondsSinceSend: 0) == 0)
        #expect(LiveWallpaperPulse.value(secondsSinceSend: 0.125) == 0.5)
        #expect(LiveWallpaperPulse.value(secondsSinceSend: 0.25) == 1)
        #expect(abs(LiveWallpaperPulse.value(secondsSinceSend: 1.15) - Float(exp(-1.0))) < 1e-6)
        #expect(abs(LiveWallpaperPulse.value(secondsSinceSend: 4.2) - Float(exp(-3.95 / 0.9))) < 1e-6)
        #expect(LiveWallpaperPulse.value(secondsSinceSend: 4.2001) == 0)
        #expect(LiveWallpaperPulse.value(secondsSinceSend: 60) == 0)
    }
    
    @Test
    func pulseRisesThenFades() {
        let rise = stride(from: 0.0, through: 0.25, by: 0.01).map { LiveWallpaperPulse.value(secondsSinceSend: $0) }
        let fade = stride(from: 0.25, through: 4.2, by: 0.05).map { LiveWallpaperPulse.value(secondsSinceSend: $0) }
        #expect(zip(rise, rise.dropFirst()).allSatisfy { $0 < $1 })
        #expect(zip(fade, fade.dropFirst()).allSatisfy { $0 > $1 })
    }
    
    @Test
    func sendPulseStartsAtTheSend() {
        var now = 10.0
        let pulse = ChatWallpaperSendPulse { now }
        #expect(pulse.value(at: 10.25) == 0)
        
        pulse.recordSend()
        #expect(pulse.lastSend == 10)
        #expect(pulse.value(at: 10) == 0)
        #expect(pulse.value(at: 10.25) == 1)
        #expect(pulse.value(at: 15) == 0)
        
        now = 20
        pulse.recordSend()
        #expect(pulse.value(at: 20.25) == 1)
    }
    
    @Test
    func aLocalEchoPulsesOnceWhenItFirstAppears() {
        var now = 10.0
        let pulse = ChatWallpaperSendPulse { now }
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        pulse.recordLocalEchoes(in: history, isSwitchingTimelines: true)
        
        pulse.recordLocalEchoes(in: history + [makeEvent(id: localEcho("txn1"), properties: .init(deliveryStatus: .sending))], isSwitchingTimelines: false)
        #expect(pulse.lastSend == 10)
        
        // Sent, then replaced by its remote echo: still the same send.
        now = 11
        pulse.recordLocalEchoes(in: history + [makeEvent(id: localEcho("txn1"), properties: .init(deliveryStatus: .sent))], isSwitchingTimelines: false)
        pulse.recordLocalEchoes(in: history + [makeEvent(id: .event(uniqueID: .init("txn1"), eventOrTransactionID: .eventID("$2")))], isSwitchingTimelines: false)
        #expect(pulse.lastSend == 10)
    }
    
    @Test
    func localEchoesFromBeforeTheTimelineOpenedDoNotPulse() {
        var now = 10.0
        let pulse = ChatWallpaperSendPulse { now }
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        let failed = makeEvent(id: localEcho("txn-failed"), properties: .init(deliveryStatus: .sendingFailed(.unknown(reason: nil))))
        
        // The timeline opens before it has loaded, then its first items include an echo from an earlier session's send queue.
        pulse.recordLocalEchoes(in: [PaginationIndicatorRoomTimelineItem(position: .start)], isSwitchingTimelines: true)
        pulse.recordLocalEchoes(in: history + [failed], isSwitchingTimelines: false)
        #expect(pulse.lastSend == nil)
        
        now = 20
        pulse.recordLocalEchoes(in: history + [failed, makeEvent(id: localEcho("txn-new"))], isSwitchingTimelines: false)
        #expect(pulse.lastSend == 20)
    }
    
    @Test
    func aLocalEchoShownBySwitchingTimelinesDoesNotPulse() {
        let pulse = ChatWallpaperSendPulse { 10 }
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        pulse.recordLocalEchoes(in: history, isSwitchingTimelines: true)
        
        pulse.recordLocalEchoes(in: history + [makeEvent(id: localEcho("txn1"))], isSwitchingTimelines: true)
        #expect(pulse.lastSend == nil)
    }
    
    @Test
    func anOpeningTimelineDropsThePulseOfAnEarlierSend() {
        let pulse = ChatWallpaperSendPulse { 10 }
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        pulse.recordLocalEchoes(in: history, isSwitchingTimelines: true)
        pulse.recordLocalEchoes(in: history + [makeEvent(id: localEcho("txn1"))], isSwitchingTimelines: false)
        #expect(pulse.value(at: 10.25) == 1)
        
        pulse.recordLocalEchoes(in: [PaginationIndicatorRoomTimelineItem(position: .start)], isSwitchingTimelines: true)
        #expect(pulse.lastSend == nil)
        #expect(pulse.value(at: 10.5) == 0)
    }
    
    @Test(arguments: [(TimelineKind.live, true), (.detached, true), (.thread(rootEventID: "$root"), false), (.pinned, false), (.media(.roomScreenLive), false)])
    func onlyTheRoomTimelinePulses(timelineKind: TimelineKind, pulses: Bool) {
        let roomID = "!pulse-\(UUID().uuidString):example.com"
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        ChatWallpaperSendPulse.recordLocalEchoes(in: history, isSwitchingTimelines: true, roomID: roomID, timelineKind: timelineKind)
        ChatWallpaperSendPulse.recordLocalEchoes(in: history + [makeEvent(id: localEcho("txn1"))], isSwitchingTimelines: false, roomID: roomID, timelineKind: timelineKind)
        #expect((ChatWallpaperSendPulse.forRoom(roomID).lastSend != nil) == pulses)
    }
    
    @Test(arguments: SentEvent.allCases)
    func aNewLocalEchoInTheTimelinePulsesOnce(event: SentEvent) async throws {
        let room = makeRoom()
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false), makeEvent(id: remoteEvent("$2"))]
        try await show(history, in: room, isSwitchingTimelines: true)
        
        try await show(history + [makeEvent(event, id: localEcho("txn1"), properties: .init(deliveryStatus: .sending))], in: room)
        let firstPulse = try #require(room.pulse.lastSend)
        
        try await show(history + [makeEvent(event, id: localEcho("txn1"), properties: .init(deliveryStatus: .sent))], in: room)
        try await show(history + [makeEvent(event, id: .event(uniqueID: .init("txn1"), eventOrTransactionID: .eventID("$3")))], in: room)
        #expect(room.pulse.lastSend == firstPulse)
    }
    
    @Test
    func historyDoesNotPulse() async throws {
        let room = makeRoom()
        let latest = [makeEvent(id: remoteEvent("$3"), isOutgoing: false), makeEvent(id: remoteEvent("$4"))]
        try await show(latest, in: room, isSwitchingTimelines: true)
        
        let older = [makeEvent(.image, id: remoteEvent("$1")), makeEvent(.sticker, id: remoteEvent("$2"))]
        try await show(older + latest, in: room)
        #expect(room.pulse.lastSend == nil)
    }
    
    @Test
    func editsDoNotPulse() async throws {
        let room = makeRoom()
        let sent = makeEvent(id: remoteEvent("$1"))
        let sending = makeEvent(id: localEcho("txn1"), properties: .init(deliveryStatus: .sending))
        try await show([sent, sending], in: room, isSwitchingTimelines: true)
        
        // The edits replace the content of both items, the first one's still on its way.
        let editedSent = makeEvent(id: sent.id, body: "Edited", properties: .init(isEdited: true, deliveryStatus: .sending))
        let editedSending = makeEvent(id: sending.id, body: "Edited", properties: .init(isEdited: true, deliveryStatus: .sending))
        try await show([editedSent, editedSending], in: room)
        #expect(room.pulse.lastSend == nil)
    }
    
    @Test
    func reactionsDoNotPulse() async throws {
        let room = makeRoom()
        let message = makeEvent(id: remoteEvent("$1"), isOutgoing: false)
        try await show([message], in: room, isSwitchingTimelines: true)
        
        let reaction = AggregatedReaction(accountOwnerID: TimelineItemSender.test.id, key: "👍", senders: [ReactionSender(id: TimelineItemSender.test.id, timestamp: .mock)])
        try await show([makeEvent(id: message.id, isOutgoing: false, properties: .init(reactions: [reaction]))], in: room)
        #expect(room.pulse.lastSend == nil)
    }
    
    @Test
    func anOwnEventFromAnotherDeviceDoesNotPulse() async throws {
        let room = makeRoom()
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        try await show(history, in: room, isSwitchingTimelines: true)
        
        try await show(history + [makeEvent(id: remoteEvent("$2"))], in: room)
        #expect(room.pulse.lastSend == nil)
    }
    
    @Test
    func aLocalEchoInAThreadDoesNotPulseTheRoom() async throws {
        let room = makeRoom(timelineKind: .thread(rootEventID: "$root"))
        let history = [makeEvent(id: remoteEvent("$root"), isOutgoing: false)]
        try await show(history, in: room, isSwitchingTimelines: true)
        
        try await show(history + [makeEvent(id: localEcho("txn1"))], in: room)
        #expect(room.pulse.lastSend == nil)
    }
    
    @Test
    func reopeningAChatStartsWithoutThePulse() async throws {
        let roomID = "!reopen-\(UUID().uuidString):example.com"
        let history = [makeEvent(id: remoteEvent("$1"), isOutgoing: false)]
        let sending = makeEvent(id: localEcho("txn1"), properties: .init(deliveryStatus: .sending))
        let room = makeRoom(id: roomID)
        try await show(history, in: room, isSwitchingTimelines: true)
        try await show(history + [sending], in: room)
        #expect(room.pulse.lastSend != nil)
        
        // Opened again within the pulse, with the message still on its way.
        let reopened = makeRoom(id: roomID)
        try await show(history + [sending], in: reopened, isSwitchingTimelines: true)
        #expect(reopened.pulse.lastSend == nil)
    }
    
    @Test
    func eachRoomHasItsOwnPulse() {
        let room = ChatWallpaperSendPulse.forRoom("!live-wallpaper-a:example.com")
        #expect(ChatWallpaperSendPulse.forRoom("!live-wallpaper-a:example.com") === room)
        #expect(ChatWallpaperSendPulse.forRoom("!live-wallpaper-b:example.com") !== room)
        
        room.recordSend()
        #expect(ChatWallpaperSendPulse.forRoom("!live-wallpaper-b:example.com").lastSend == nil)
    }
    
    // MARK: - Helpers
    
    /// A pulse origin in the canvas's coordinates, from the top left.
    private func spotInCanvas(_ origin: SIMD2<Float>, of layout: LiveWallpaperLayout) -> CGPoint {
        let scaleX = layout.drawableSize.width / layout.rect.width
        let scaleY = layout.drawableSize.height / layout.rect.height
        return CGPoint(x: CGFloat(origin.x) / scaleX + layout.rect.minX,
                       y: (layout.drawableSize.height - CGFloat(origin.y)) / scaleY + layout.rect.minY)
    }
    
    /// The visible chat of a 758-point canvas 116 points down SwiftUI's global space, over a 34-point home indicator.
    private func visibleChat(canvasGlobalTop: CGFloat? = 116,
                             composerGlobalTop: CGFloat?,
                             bottomInset: CGFloat = 34,
                             windowBottomInset: CGFloat? = 34) -> (top: CGFloat, bottom: CGFloat) {
        LiveWallpaperLayout.visibleChat(canvasHeight: 758,
                                        canvasGlobalTop: canvasGlobalTop,
                                        composerGlobalTop: composerGlobalTop,
                                        topInset: 0,
                                        bottomInset: bottomInset,
                                        windowBottomInset: windowBottomInset)
    }
    
    /// An animating frame's uniforms with the chat seen from the canvas's top down to `visibleBottom`.
    private func frame(in layout: LiveWallpaperLayout, visibleBottom: CGFloat) -> LiveWallpaperUniforms {
        LiveWallpaperUniforms.frame(in: layout,
                                    origin: layout.pulseOrigin(visibleTop: 0, visibleBottom: visibleBottom),
                                    isDark: false,
                                    time: 0,
                                    pulse: 0.6,
                                    animates: true)
    }
    
    /// Draws `count` frames ending `interval` apart from `start`, each taking `gpuTime`, and returns whether the watchdog tripped.
    private func drawFrames(into watchdog: inout WallpaperFrameWatchdog,
                            count: Int,
                            every interval: TimeInterval,
                            taking gpuTime: TimeInterval,
                            from start: TimeInterval) -> Bool {
        var tripped = false
        for frame in 0..<count {
            tripped = watchdog.recordFrame(duration: gpuTime, endingAt: start + Double(frame) * interval) || tripped
        }
        return tripped
    }
    
    /// Draws frames ending `interval` apart from `start` for `duration` seconds, each taking `gpuTime`, and returns whether the watchdog tripped.
    private func drawFrames(into watchdog: inout WallpaperFrameWatchdog,
                            every interval: TimeInterval,
                            taking gpuTime: TimeInterval,
                            from start: TimeInterval,
                            for duration: TimeInterval) -> Bool {
        var tripped = false
        for time in stride(from: start, through: start + duration, by: interval) {
            tripped = watchdog.recordFrame(duration: gpuTime, endingAt: time) || tripped
        }
        return tripped
    }
    
    nonisolated enum SentEvent: CaseIterable {
        case text, image, sticker
    }
    
    private struct Room {
        let viewModel: TimelineViewModel
        let timelineController: TimelineControllerMock
        
        var pulse: ChatWallpaperSendPulse {
            ChatWallpaperSendPulse.forRoom(viewModel.context.viewState.roomID)
        }
    }
    
    /// A timeline in a room of its own unless given an ID, so no other test's sends reach its pulse.
    private func makeRoom(id: String = UUID().uuidString, timelineKind: TimelineKind = .live) -> Room {
        let timelineController = TimelineControllerMock(.init(timelineKind: timelineKind, timelineItems: []))
        let viewModel = TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(id: id, name: "Live wallpaper")),
                                          focussedEventID: nil,
                                          timelineController: timelineController,
                                          userSession: UserSessionMock(.init(clientProxy: ClientProxyMock(.init()))),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: UserIndicatorControllerMock(),
                                          appMediator: AppMediatorMock(.init()),
                                          analyticsService: AnalyticsServiceMock(.init()),
                                          emojiProvider: EmojiProvider(userSettings: .mock()),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        return Room(viewModel: viewModel, timelineController: timelineController)
    }
    
    /// Sends the items as a timeline update and waits until the timeline has handled it.
    private func show(_ items: [RoomTimelineItemProtocol], in room: Room, isSwitchingTimelines: Bool = false) async throws {
        let marker = SeparatorRoomTimelineItem(id: .randomVirtual, timestamp: .mock)
        room.timelineController.callbacks.send(.updatedTimelineItems(timelineItems: items + [marker], isSwitchingTimelines: isSwitchingTimelines))
        try await waitUntil { room.viewModel.context.viewState.timelineState.itemsDictionary[marker.id.uniqueID] != nil }
    }
    
    private func makeEvent(_ event: SentEvent = .text,
                           id: TimelineItemIdentifier,
                           isOutgoing: Bool = true,
                           body: String = "Hello",
                           properties: RoomTimelineItemProperties = .init()) -> RoomTimelineItemProtocol {
        let sender = isOutgoing ? TimelineItemSender.test : TimelineItemSender(id: "@bob:example.com")
        switch event {
        case .text:
            return TextRoomTimelineItem(id: id, timestamp: .mock, isOutgoing: isOutgoing, isEditable: isOutgoing, canBeRepliedTo: true,
                                        sender: sender, content: .init(body: body), properties: properties)
        case .image:
            return ImageRoomTimelineItem(id: id, timestamp: .mock, isOutgoing: isOutgoing, isEditable: isOutgoing, canBeRepliedTo: true,
                                         sender: sender, content: .init(filename: "photo.jpg", caption: body, imageInfo: .mockImage, thumbnailInfo: nil),
                                         properties: properties)
        case .sticker:
            return StickerRoomTimelineItem(id: id, body: body, timestamp: .mock, isOutgoing: isOutgoing, isEditable: false, canBeRepliedTo: true,
                                           sender: sender, imageInfo: .mockImage, properties: properties)
        }
    }
    
    private func localEcho(_ transactionID: String) -> TimelineItemIdentifier {
        .event(uniqueID: .init(transactionID), eventOrTransactionID: .transactionID(transactionID))
    }
    
    private func remoteEvent(_ eventID: String) -> TimelineItemIdentifier {
        .event(uniqueID: .init(eventID), eventOrTransactionID: .eventID(eventID))
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
