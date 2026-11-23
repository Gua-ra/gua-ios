//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MetalKit
import SwiftUI

extension EnvironmentValues {
    /// Set only in the chat and the theme preview; elsewhere an artwork shows its still.
    @Entry var chatWallpaperSendPulse: ChatWallpaperSendPulse?
    /// A full-screen call hides the chat without presenting over it, so the cover check can't see it.
    @Entry var isChatHiddenByOverlay = false
}

extension View {
    /// Places the send pulse above this view's top edge.
    func reportsChatWallpaperComposerTop(to sendPulse: ChatWallpaperSendPulse) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sendPulse.composerTop = $0 }
    }
}

/// The still, moved by the tilt, with a live artwork's shader drawn over it once its first frame is ready.
struct ChatLiveWallpaperView: View {
    let artwork: ChatArtwork
    let sendPulse: ChatWallpaperSendPulse
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.isChatHiddenByOverlay) private var isHiddenByOverlay
    
    @State private var isOnScreen = false
    @State private var globalTop: CGFloat?
    @State private var parallax = WallpaperParallax()
    
    /// Off in previews and tests, so snapshots never depend on a running clock.
    static var isEnabled: Bool {
        !ProcessInfo.isRunningTests && !ProcessInfo.isXcodePreview
    }
    
    var body: some View {
        let policy = LiveWallpaperConditions.shared.policy(for: artwork, isOnScreen: isOnScreen, isCovered: isHiddenByOverlay, reducesMotion: reducesMotion)
        // Where tilt is supported the still stays oversized even when the tilt stops, so its framing never jumps.
        let stillParallax = WallpaperTiltSensor.shared.isSupported ? parallax : nil
        let rendersLive = artwork.isLive && policy.motion != .still
        let tilts = stillParallax != nil && policy.tiltMotion != .still
        
        ChatArtworkView(artwork: artwork, parallax: stillParallax)
            .overlay {
                if rendersLive || tilts {
                    ChatLiveWallpaperRepresentable(artwork: artwork,
                                                   policy: policy,
                                                   isDark: colorScheme == .dark,
                                                   sendPulse: sendPulse,
                                                   parallax: stillParallax,
                                                   globalTop: globalTop)
                        .id(artwork)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { globalTop = $0 }
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .onChange(of: policy.tiltMotion == .still) { _, isStill in
                if isStill {
                    settleTilt()
                }
            }
    }
    
    static func isShown(for artwork: ChatArtwork,
                        sendPulse: ChatWallpaperSendPulse?,
                        isEnabled: Bool = isEnabled,
                        isTiltSupported: Bool = WallpaperTiltSensor.shared.isSupported) -> Bool {
        isEnabled && sendPulse != nil && (artwork.isLive || isTiltSupported)
    }
    
    /// Ignores the conditions that only pause the artwork.
    static func canAnimate(_ artwork: ChatArtwork, reducesMotion: Bool, isEnabled: Bool = isEnabled) -> Bool {
        isEnabled && artwork.isLive && LiveWallpaperConditions.shared.policy(for: artwork, isOnScreen: true, reducesMotion: reducesMotion).motion != .still
    }
    
    /// Eases the still back to rest from the last applied tilt, or snaps there under Reduce Motion.
    private func settleTilt() {
        let parallax = parallax
        withAnimation(nil) {
            if reducesMotion {
                parallax.tilt = .zero
            } else {
                parallax.moveStillToAppliedTilt()
            }
        }
        parallax.forgetAppliedTilt()
        guard !reducesMotion else { return }
        // An ease in this update would start where the still was hidden, not where the last frame was drawn.
        Task {
            withAnimation(.easeOut(duration: 0.3)) {
                parallax.tilt = .zero
            }
        }
    }
}

/// The live frame covers the still's whole aspect-fill rect, so its first frame matches the still. It depends on the view
/// size alone, so the keyboard never moves the picture.
struct LiveWallpaperLayout: Equatable {
    /// Caps the drawable at this multiple of the visible area, so a wide view never holds a huge, mostly hidden one.
    static let maximumAreaRatio: CGFloat = 2
    /// The shaders' default send-pulse spot, as a share of the render target from its bottom-left corner.
    static let pulseSpot = CGPoint(x: 0.83, y: 0.113)
    /// Any less and the composer has reached the top bar, give or take rounding.
    static let minimumVisibleChatHeight: CGFloat = 4
    
    let viewSize: CGSize
    /// The still's rect at rest; it overflows the view on one axis, or on every side where the artwork tilts.
    let rect: CGRect
    let drawableSize: CGSize
    /// The drawable's pixels that can be seen plus one all round, so scaling up never blends in a pixel that was not drawn.
    let scissor: CGRect?
    
    init(artwork: ChatArtwork, viewSize: CGSize, displayScale: CGFloat, tilts: Bool = false) {
        self.viewSize = viewSize
        rect = if tilts {
            WallpaperStillLayout(viewSize: viewSize).imageRect(anchor: artwork.anchor, at: .zero)
        } else {
            ChatBackgroundPhotoLayout.rect(of: ChatArtwork.pixelSize, filling: viewSize, alignX: artwork.anchor.x, alignY: artwork.anchor.y)
        }
        
        let visibleArea = viewSize.width * viewSize.height
        let rectArea = rect.width * rect.height
        let cap = rectArea > 0 ? min(1, (Self.maximumAreaRatio * visibleArea / rectArea).squareRoot()) : 1
        let scale = max(displayScale, 1) / 2 * cap
        drawableSize = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        
        guard rect.width > 0, rect.height > 0, drawableSize.width >= 1, drawableSize.height >= 1 else {
            scissor = nil
            return
        }
        
        let scaleX = drawableSize.width / rect.width
        let scaleY = drawableSize.height / rect.height
        
        let shown = CGRect(origin: .zero, size: viewSize).intersection(rect)
        if shown.isEmpty {
            scissor = nil
        } else {
            let minX = max(((shown.minX - rect.minX) * scaleX).rounded(.down) - 1, 0)
            let minY = max(((shown.minY - rect.minY) * scaleY).rounded(.down) - 1, 0)
            let maxX = min(((shown.maxX - rect.minX) * scaleX).rounded(.up) + 1, drawableSize.width)
            let maxY = min(((shown.maxY - rect.minY) * scaleY).rounded(.up) + 1, drawableSize.height)
            scissor = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
    
    /// `u_origin`: the shaders' default spot placed on the visible chat rather than the whole `rect`, which reaches under the
    /// composer and the keyboard. In drawable pixels from the bottom left.
    func pulseOrigin(visibleTop: CGFloat, visibleBottom: CGFloat) -> SIMD2<Float> {
        guard rect.width > 0, rect.height > 0, drawableSize.width >= 1, drawableSize.height >= 1 else { return .zero }
        
        // With no chat left (landscape with the keyboard open), the spot sits on the top bar's edge.
        let top = min(max(visibleTop, 0), viewSize.height)
        let bottom = min(max(visibleBottom, top), viewSize.height)
        let spotX = viewSize.width * Self.pulseSpot.x
        let spotY = bottom - (bottom - top) * Self.pulseSpot.y
        
        let scaleX = drawableSize.width / rect.width
        let scaleY = drawableSize.height / rect.height
        return SIMD2(Float((spotX - rect.minX) * scaleX), Float(drawableSize.height - (spotY - rect.minY) * scaleY))
    }
    
    /// The visible chat's unclamped edges in the canvas: from the top inset down to the composer, or to the home indicator
    /// until both global tops are known.
    static func visibleChat(canvasHeight: CGFloat,
                            canvasGlobalTop: CGFloat?,
                            composerGlobalTop: CGFloat?,
                            topInset: CGFloat,
                            bottomInset: CGFloat,
                            windowBottomInset: CGFloat?) -> (top: CGFloat, bottom: CGFloat) {
        if let canvasGlobalTop, let composerGlobalTop {
            return (topInset, composerGlobalTop - canvasGlobalTop)
        }
        // The window's inset is the home indicator alone; the canvas's own can also hold the keyboard.
        return (topInset, canvasHeight - min(bottomInset, windowBottomInset ?? 0))
    }
    
    static func showsChat(visibleTop: CGFloat, visibleBottom: CGFloat) -> Bool {
        visibleBottom - visibleTop >= minimumVisibleChatHeight
    }
}

extension LiveWallpaperUniforms {
    /// A held frame never shows the pulse but keeps its tilt.
    static func frame(in layout: LiveWallpaperLayout,
                      origin: SIMD2<Float>,
                      tilt: SIMD2<Double> = .zero,
                      isDark: Bool,
                      time: Float,
                      pulse: Float,
                      animates: Bool) -> LiveWallpaperUniforms {
        LiveWallpaperUniforms(res: SIMD2(Float(layout.drawableSize.width), Float(layout.drawableSize.height)),
                              tilt: SIMD2(Float(tilt.x), Float(tilt.y)),
                              origin: origin,
                              time: time,
                              dark: isDark ? 1 : 0,
                              pulse: animates ? pulse : 0)
    }
}

private struct ChatLiveWallpaperRepresentable: UIViewRepresentable {
    let artwork: ChatArtwork
    let policy: WallpaperMotionPolicy
    let isDark: Bool
    let sendPulse: ChatWallpaperSendPulse
    let parallax: WallpaperParallax?
    let globalTop: CGFloat?
    
    func makeUIView(context: Context) -> ChatLiveWallpaperUIView {
        ChatLiveWallpaperUIView(artwork: artwork, parallax: parallax)
    }
    
    func updateUIView(_ view: ChatLiveWallpaperUIView, context: Context) {
        view.sendPulse = sendPulse
        view.globalTop = globalTop
        view.isDark = isDark
        view.policy = policy
    }
}

/// Draws the shader in exactly the still's rect and drives the tilt; a static artwork only tilts.
private final class ChatLiveWallpaperUIView: UIView, MTKViewDelegate {
    /// Polled, since presentations, hidden windows and the composer's position post no notification.
    private static let coverCheckInterval: TimeInterval = 0.25
    
    var sendPulse: ChatWallpaperSendPulse?
    var globalTop: CGFloat?
    
    var isDark = false {
        didSet {
            if isDark != oldValue {
                requestPausedFrame()
            }
        }
    }
    
    /// SwiftUI's policy, which can't see the scene's state or what UIKit presents over the chat.
    var policy = WallpaperMotionPolicy(isOnScreen: false) {
        didSet {
            if policy != oldValue {
                applyMotion()
            }
        }
    }
    
    private let artwork: ChatArtwork
    private let parallax: WallpaperParallax?
    private lazy var metalView = MTKView()
    private var pipeline: MTLRenderPipelineState?
    private var layout: LiveWallpaperLayout?
    private var clock: LiveWallpaperClock
    private var watchdog = WallpaperFrameWatchdog()
    /// Bumped on every pause, so frames drawn before it never reach the watchdog.
    private var watchdogRun = 0
    /// Not `scenePhase`, which only a SwiftUI scene keeps up to date.
    private var isSceneActive = false
    private var isCovered = false
    private var coverCheck: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastPulse: Float = 0
    private var hasDrawnFrame = false
    /// Bumped when the frame is hidden, so a frame drawn earlier never shows it again.
    private var frameGeneration = 0
    /// A paused view draws a fresh frame once the GPU may be used.
    private var needsPausedFrame = true
    private var tiltTracker = WallpaperTiltTracker()
    private var isTilting = false
    
    private var motion: WallpaperMotionPolicy.Motion {
        guard pipeline != nil, !watchdog.hasTripped else { return .still }
        return policy.including(isInWindow: window != nil, isSceneActive: isSceneActive, isCovered: isCovered).motion
    }
    
    private var tiltMotion: WallpaperMotionPolicy.Motion {
        guard parallax != nil else { return .still }
        return policy.including(isInWindow: window != nil, isSceneActive: isSceneActive, isCovered: isCovered).tiltMotion
    }
    
    private var visibleChat: (top: CGFloat, bottom: CGFloat) {
        LiveWallpaperLayout.visibleChat(canvasHeight: bounds.height,
                                        canvasGlobalTop: globalTop,
                                        composerGlobalTop: sendPulse?.composerTop,
                                        topInset: safeAreaInsets.top,
                                        bottomInset: safeAreaInsets.bottom,
                                        windowBottomInset: window?.safeAreaInsets.bottom)
    }
    
    private var pulseOrigin: SIMD2<Float> {
        guard let layout else { return .zero }
        let chat = visibleChat
        return layout.pulseOrigin(visibleTop: chat.top, visibleBottom: chat.bottom)
    }
    
    /// Apps must not use the GPU in the background, but an inactive scene (Control Center, the app switcher) still may.
    private var canUseGPU: Bool {
        switch window?.windowScene?.activationState {
        case .foregroundActive, .foregroundInactive: true
        default: false
        }
    }
    
    /// The app lock screen hides the window, sheets and menus present over this view's controller or an ancestor, and a
    /// composer up at the top bar leaves no chat to see.
    private var isCoveredInUIKit: Bool {
        let chat = visibleChat
        if window?.isHidden == true || !LiveWallpaperLayout.showsChat(visibleTop: chat.top, visibleBottom: chat.bottom) {
            return true
        }
        var controller = sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
        while let current = controller {
            if current.presentedViewController != nil {
                return true
            }
            controller = current.parent
        }
        return false
    }
    
    init(artwork: ChatArtwork, parallax: WallpaperParallax?) {
        self.artwork = artwork
        self.parallax = parallax
        clock = LiveWallpaperClock(stillTime: artwork.stillTime ?? 0)
        super.init(frame: .zero)
        
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
            view.setNeedsLayout()
        }
        
        // Locking the screen, the app switcher and Control Center all deactivate the scene.
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] notification in
                self?.sceneDidChange(notification.object, isActive: true)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)
            .sink { [weak self] notification in
                self?.sceneDidChange(notification.object, isActive: false)
            }
            .store(in: &cancellables)
        
        if artwork.isLive {
            setUpRenderer()
        }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        guard artwork.isLive else { return }
        
        let layout = LiveWallpaperLayout(artwork: artwork, viewSize: bounds.size, displayScale: traitCollection.displayScale, tilts: parallax != nil)
        guard layout != self.layout else { return }
        self.layout = layout
        metalView.frame = layout.rect
        metalView.drawableSize = layout.drawableSize
        requestPausedFrame()
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        isSceneActive = window?.windowScene?.activationState == .foregroundActive
        setNeedsLayout()
        applyMotion()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    
    func draw(in view: MTKView) {
        let currentMotion = motion
        guard currentMotion != .still, window != nil, let pipeline, let layout, let commandQueue = LiveWallpaperShader.commandQueue else {
            return
        }
        guard canUseGPU else {
            if needsPausedFrame {
                hideFrame()
            }
            return
        }
        
        let now = CACurrentMediaTime()
        let animates = currentMotion == .animating
        if animates {
            clock.start(at: now)
        }
        
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Every pixel that can be seen is drawn, so there is nothing to load or clear.
        pass.colorAttachments[0].loadAction = .dontCare
        let uniforms = LiveWallpaperUniforms.frame(in: layout,
                                                   origin: pulseOrigin,
                                                   tilt: parallax?.appliedTilt ?? .zero,
                                                   isDark: isDark,
                                                   time: clock.time(at: now),
                                                   pulse: Float(sendPulse?.value(at: now) ?? 0),
                                                   animates: animates)
        LiveWallpaperShader.encode(pipeline, uniforms: uniforms, pass: pass, scissor: layout.scissor.map { MTLScissorRect($0) }, into: commandBuffer)
        
        let generation = frameGeneration
        let run = animates ? watchdogRun : nil
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let isComplete = buffer.status == .completed
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            let end = buffer.gpuEndTime
            Task { @MainActor in
                self?.frameDidComplete(isComplete: isComplete, generation: generation, watchdogRun: run, gpuTime: gpuTime, end: end)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastPulse = uniforms.pulse
        needsPausedFrame = false
    }
    
    private func setUpRenderer() {
        metalView.device = LiveWallpaperShader.device
        metalView.colorPixelFormat = LiveWallpaperShader.pixelFormat
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.preferredFramesPerSecond = WallpaperFrameWatchdog.framesPerSecond
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.isUserInteractionEnabled = false
        // Hidden until the first frame is ready, so the still shows meanwhile.
        metalView.alpha = 0
        (metalView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalView.delegate = self
        addSubview(metalView)
        
        Task { [weak self, artwork] in
            let pipeline = await LiveWallpaperPipelines.shared.pipeline(for: artwork)
            guard let self, let pipeline else { return }
            self.pipeline = pipeline
            applyMotion()
        }
    }
    
    private func applyMotion() {
        updateCoverCheck()
        updateTilt()
        // Nothing draws until the pipeline is ready, and a static artwork never gets one.
        guard pipeline != nil else { return }
        
        switch motion {
        case .animating:
            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = false
        case .paused, .still:
            let wasAnimating = !metalView.isPaused
            clock.pause(at: CACurrentMediaTime())
            watchdog.restart()
            watchdogRun += 1
            metalView.isPaused = true
            metalView.enableSetNeedsDisplay = true
            if wasAnimating, lastPulse > 0 {
                // A held frame shows no pulse. Drawn at once, as the scene may be on its way to the background.
                needsPausedFrame = true
                if canUseGPU {
                    metalView.draw()
                } else {
                    hideFrame()
                }
            } else {
                drawPausedFrameIfNeeded()
            }
        }
    }
    
    private func updateTilt() {
        let isTilting = tiltMotion == .animating
        guard isTilting != self.isTilting else { return }
        self.isTilting = isTilting
        
        if isTilting {
            WallpaperTiltSensor.shared.subscribe(self) { [weak self] rate, time in
                self?.sampleTilt(rate: rate, at: time)
            }
        } else {
            WallpaperTiltSensor.shared.unsubscribe(self)
            tiltTracker.stop()
        }
    }
    
    private func sampleTilt(rate: SIMD3<Double>, at time: TimeInterval) {
        let deviceTilt = tiltTracker.sample(rate: rate, at: time)
        let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        // While a live frame covers the still, moving the still would only cost redraws.
        parallax?.apply(WallpaperScreenRotation(orientation).interfaceTilt(deviceTilt), movesStill: !hasDrawnFrame)
    }
    
    private func sceneDidChange(_ scene: Any?, isActive: Bool) {
        guard let scene = scene as? UIScene, scene === window?.windowScene, isActive != isSceneActive else { return }
        isSceneActive = isActive
        applyMotion()
    }
    
    private func requestPausedFrame() {
        needsPausedFrame = true
        drawPausedFrameIfNeeded()
    }
    
    private func drawPausedFrameIfNeeded() {
        guard needsPausedFrame, pipeline != nil, metalView.isPaused else { return }
        if canUseGPU {
            metalView.setNeedsDisplay()
        } else {
            // The stale frame can't be redrawn yet, so the still shows until it can.
            hideFrame()
        }
    }
    
    private func hideFrame() {
        frameGeneration += 1
        hasDrawnFrame = false
        metalView.alpha = 0
        // A view leaving its window may be removed for a still condition, whose ease to rest this would cut short.
        if window != nil {
            parallax?.moveStillToAppliedTilt()
        }
    }
    
    private func frameDidComplete(isComplete: Bool, generation: Int, watchdogRun run: Int?, gpuTime: TimeInterval, end: TimeInterval) {
        if isComplete, generation == frameGeneration, !hasDrawnFrame {
            hasDrawnFrame = true
            metalView.alpha = 1
        }
        
        guard let run, run == watchdogRun, gpuTime > 0 else { return }
        if watchdog.recordFrame(duration: gpuTime, endingAt: end) {
            applyMotion()
            LiveWallpaperConditions.shared.reportSlowFrames()
        }
    }
    
    private func updateCoverCheck() {
        let isNeeded = (pipeline != nil || parallax != nil) && window != nil && policy.isOnScreen && isSceneActive
        
        if !isNeeded {
            coverCheck?.invalidate()
            coverCheck = nil
            isCovered = false
        } else if coverCheck == nil {
            isCovered = isCoveredInUIKit
            coverCheck = Timer.scheduledTimer(withTimeInterval: Self.coverCheckInterval, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated {
                    self.checkCover()
                }
            }
        }
    }
    
    private func checkCover() {
        let isCovered = isCoveredInUIKit
        guard isCovered != self.isCovered else { return }
        self.isCovered = isCovered
        applyMotion()
    }
}

private extension MTLScissorRect {
    init(_ rect: CGRect) {
        self.init(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
    }
}
