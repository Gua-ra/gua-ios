//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
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
    func watchdogTripsAfterTwoSecondsOfSlowFrames() {
        var watchdog = WallpaperFrameWatchdog()
        let trippedEarly = drawFrames(into: &watchdog, every: 0.06, taking: 0.06, from: 0, for: 1.9)
        let tripped = drawFrames(into: &watchdog, every: 0.06, taking: 0.06, from: 1.92, for: 0.2)
        #expect(!trippedEarly)
        #expect(tripped)
        #expect(watchdog.hasTripped)
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
    func watchdogAcceptsFramesAtTheLimit() {
        var watchdog = WallpaperFrameWatchdog()
        let duration = WallpaperFrameWatchdog.limit * 0.99
        let tripped = drawFrames(into: &watchdog, every: duration, taking: duration, from: 0, for: 5)
        #expect(!tripped)
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
        let trippedBefore = drawFrames(into: &watchdog, every: 0.06, taking: 0.06, from: 0, for: 1.5)
        
        watchdog.restart()
        // The slow time before the pause no longer counts.
        let trippedAfter = drawFrames(into: &watchdog, every: 0.06, taking: 0.06, from: 30, for: 1.5)
        let trippedLater = drawFrames(into: &watchdog, every: 0.06, taking: 0.06, from: 31.56, for: 0.6)
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
    
    @Test(arguments: [CGSize(width: 402, height: 758), CGSize(width: 874, height: 340), CGSize(width: 820, height: 1106), CGSize(width: 1376, height: 950)])
    func thePulseSpotIsInTheVisibleChat(viewSize: CGSize) {
        for artwork in ChatArtwork.allCases where artwork.isLive {
            let layout = LiveWallpaperLayout(artwork: artwork, viewSize: viewSize, displayScale: 3)
            let scaleX = layout.drawableSize.width / layout.rect.width
            let scaleY = layout.drawableSize.height / layout.rect.height
            let spot = CGPoint(x: CGFloat(layout.pulseOrigin.x) / scaleX + layout.rect.minX,
                               y: (layout.drawableSize.height - CGFloat(layout.pulseOrigin.y)) / scaleY + layout.rect.minY)
            
            // The same share of the chat as the shaders' default spot is of their render target.
            #expect(abs(spot.x - viewSize.width * 0.83) < 0.5, "\(artwork.id) \(viewSize)")
            #expect(abs(spot.y - viewSize.height * (1 - 0.113)) < 0.5, "\(artwork.id) \(viewSize)")
        }
    }
    
    @Test
    func aChatShapedLikeTheStillKeepsTheShadersOwnSpot() {
        let layout = LiveWallpaperLayout(artwork: .glassDrops, viewSize: CGSize(width: 430, height: 932), displayScale: 3)
        #expect(abs(layout.pulseOrigin.x - Float(layout.drawableSize.width) * 0.83) < 0.5)
        #expect(abs(layout.pulseOrigin.y - Float(layout.drawableSize.height) * 0.113) < 0.5)
    }
    
    @Test
    func uniformsComeFromTheLayoutAndTheMotion() {
        let layout = LiveWallpaperLayout(artwork: .ipe, viewSize: CGSize(width: 402, height: 758), displayScale: 3)
        
        let animating = LiveWallpaperUniforms.frame(in: layout, isDark: true, time: 25.5, pulse: 0.6, animates: true)
        #expect(animating.res == SIMD2(Float(layout.drawableSize.width), Float(layout.drawableSize.height)))
        #expect(animating.origin == layout.pulseOrigin)
        #expect(animating.tilt == .zero)
        #expect(animating.time == 25.5)
        #expect(animating.dark == 1)
        #expect(animating.pulse == 0.6)
        
        let held = LiveWallpaperUniforms.frame(in: layout, isDark: false, time: 25.5, pulse: 0.6, animates: false)
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
    
    @Test(arguments: [(TimelineKind.live, true), (.detached, true), (.thread(rootEventID: "$root"), false), (.pinned, false), (.media(.roomScreenLive), false)])
    func onlyTheRoomTimelinePulses(timelineKind: TimelineKind, pulses: Bool) {
        let roomID = "!pulse-\(UUID().uuidString):example.com"
        ChatWallpaperSendPulse.recordOwnSend(inRoom: roomID, timelineKind: timelineKind)
        #expect((ChatWallpaperSendPulse.forRoom(roomID).lastSend != nil) == pulses)
    }
    
    @Test
    func sendingAMessagePulses() async throws {
        let room = makeRoom()
        
        room.viewModel.process(composerAction: .sendMessage(plain: "Hello", html: nil, mode: .default, intentionalMentions: .empty))
        try await waitUntil { room.timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsCallsCount == 1 }
        
        #expect(ChatWallpaperSendPulse.forRoom(room.viewModel.context.viewState.roomID).lastSend != nil)
    }
    
    @Test
    func sendingAReplyPulses() async throws {
        let room = makeRoom()
        let mode = ComposerMode.reply(eventID: "$parent", replyDetails: .notLoaded(eventID: "$parent"), isThread: false)
        
        room.viewModel.process(composerAction: .sendMessage(plain: "Hello", html: nil, mode: mode, intentionalMentions: .empty))
        try await waitUntil { room.timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsCallsCount == 1 }
        
        #expect(ChatWallpaperSendPulse.forRoom(room.viewModel.context.viewState.roomID).lastSend != nil)
    }
    
    @Test
    func editingAMessageDoesNotPulse() async throws {
        let room = makeRoom()
        let mode = ComposerMode.edit(originalEventOrTransactionID: .eventID("$edited"), type: .default)
        
        room.viewModel.process(composerAction: .sendMessage(plain: "Hello", html: nil, mode: mode, intentionalMentions: .empty))
        try await waitUntil { room.timelineController.editMessageHtmlIntentionalMentionsCallsCount == 1 }
        
        #expect(ChatWallpaperSendPulse.forRoom(room.viewModel.context.viewState.roomID).lastSend == nil)
    }
    
    @Test
    func joinCommandDoesNotPulse() async throws {
        let room = makeRoom()
        
        room.viewModel.process(composerAction: .sendMessage(plain: "/join #elsewhere:example.com", html: nil, mode: .default, intentionalMentions: .empty))
        try await waitUntil { room.clientProxy.resolveRoomAliasCallsCount == 1 }
        
        #expect(room.timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsCallsCount == 0)
        #expect(ChatWallpaperSendPulse.forRoom(room.viewModel.context.viewState.roomID).lastSend == nil)
    }
    
    @Test
    func sendingInAThreadDoesNotPulseTheRoom() async throws {
        let room = makeRoom(timelineKind: .thread(rootEventID: "$root"))
        
        room.viewModel.process(composerAction: .sendMessage(plain: "Hello", html: nil, mode: .default, intentionalMentions: .empty))
        try await waitUntil { room.timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsCallsCount == 1 }
        
        #expect(ChatWallpaperSendPulse.forRoom(room.viewModel.context.viewState.roomID).lastSend == nil)
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
    
    private struct Room {
        let viewModel: TimelineViewModel
        let timelineController: TimelineControllerMock
        let clientProxy: ClientProxyMock
    }
    
    /// A timeline in a room of its own, whose `/join` finds no room rather than crashing the mock.
    private func makeRoom(timelineKind: TimelineKind = .live) -> Room {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.resolveRoomAliasReturnValue = .failure(.failedResolvingRoomAlias)
        let timelineController = TimelineControllerMock(.init(timelineKind: timelineKind))
        let viewModel = TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "Live wallpaper")),
                                          focussedEventID: nil,
                                          timelineController: timelineController,
                                          userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: UserIndicatorControllerMock(),
                                          appMediator: AppMediatorMock(.init()),
                                          analyticsService: AnalyticsServiceMock(.init()),
                                          emojiProvider: EmojiProvider(userSettings: .mock()),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        return Room(viewModel: viewModel, timelineController: timelineController, clientProxy: clientProxy)
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
