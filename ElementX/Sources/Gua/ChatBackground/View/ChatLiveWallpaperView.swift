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
    /// Set where a live artwork may animate (the chat and the full-screen theme preview); everywhere else shows its still.
    @Entry var chatWallpaperSendPulse: ChatWallpaperSendPulse?
    /// A full-screen call over the tabs hides the chat without presenting anything over it.
    @Entry var isChatHiddenByOverlay = false
}

extension View {
    /// Reports this view's top edge as the bottom of the chat that a live wallpaper's send pulse shows in.
    func reportsChatWallpaperComposerTop(to sendPulse: ChatWallpaperSendPulse) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sendPulse.composerTop = $0 }
    }
}

/// A live artwork's shader, drawn over its still once the first frame is ready.
struct ChatLiveWallpaperView: View {
    let artwork: ChatArtwork
    let sendPulse: ChatWallpaperSendPulse
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.isChatHiddenByOverlay) private var isHiddenByOverlay
    
    @State private var isOnScreen = false
    /// The top edge in the space `ChatWallpaperSendPulse.composerTop` is reported in.
    @State private var globalTop: CGFloat?
    
    /// Previews and tests always show the still, so snapshots never depend on a running clock.
    static var isEnabled: Bool {
        !ProcessInfo.isRunningTests && !ProcessInfo.isXcodePreview
    }
    
    var body: some View {
        let policy = LiveWallpaperConditions.shared.policy(for: artwork, isOnScreen: isOnScreen, isCovered: isHiddenByOverlay, reducesMotion: reducesMotion)
        
        Color.clear
            .overlay {
                if policy.motion != .still {
                    ChatLiveWallpaperRepresentable(artwork: artwork,
                                                   policy: policy,
                                                   isDark: colorScheme == .dark,
                                                   sendPulse: sendPulse,
                                                   globalTop: globalTop)
                        .id(artwork)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { globalTop = $0 }
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
    }
    
    /// Whether a chat background with this artwork gets the renderer: only where a send pulse is set, and never in previews or tests.
    static func isShown(for artwork: ChatArtwork, sendPulse: ChatWallpaperSendPulse?, isEnabled: Bool = isEnabled) -> Bool {
        isEnabled && artwork.isLive && sendPulse != nil
    }
    
    /// Whether the artwork can move at all right now, leaving out what only pauses it.
    static func canAnimate(_ artwork: ChatArtwork, reducesMotion: Bool, isEnabled: Bool = isEnabled) -> Bool {
        isEnabled && artwork.isLive && LiveWallpaperConditions.shared.policy(for: artwork, isOnScreen: true, reducesMotion: reducesMotion).motion != .still
    }
}

/// Where the live renderer draws in a view: the still's whole aspect-fill rect, so its first frame is the still the view showed.
/// It depends on the view's size alone, so the composer and the keyboard never move the picture.
struct LiveWallpaperLayout: Equatable {
    /// A drawable larger than this many times the visible area gets fewer pixels, so a wide view never holds a huge, mostly hidden one.
    static let maximumAreaRatio: CGFloat = 2
    /// The shaders' default send-pulse spot, as a share of the render target from its bottom-left corner.
    static let pulseSpot = CGPoint(x: 0.83, y: 0.113)
    
    let viewSize: CGSize
    /// The still's aspect-fill rect in the view's coordinates; it reaches past the view on one axis.
    let rect: CGRect
    let drawableSize: CGSize
    /// The drawable's pixels that can be seen plus one all round, so scaling up never blends in a pixel that was not drawn.
    let scissor: CGRect?
    
    init(artwork: ChatArtwork, viewSize: CGSize, displayScale: CGFloat) {
        self.viewSize = viewSize
        rect = ChatBackgroundPhotoLayout.rect(of: ChatArtwork.pixelSize, filling: viewSize, alignX: artwork.anchor.x, alignY: artwork.anchor.y)
        
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
        if shown.isNull || shown.isEmpty {
            scissor = nil
        } else {
            let minX = max(((shown.minX - rect.minX) * scaleX).rounded(.down) - 1, 0)
            let minY = max(((shown.minY - rect.minY) * scaleY).rounded(.down) - 1, 0)
            let maxX = min(((shown.maxX - rect.minX) * scaleX).rounded(.up) + 1, drawableSize.width)
            let maxY = min(((shown.maxY - rect.minY) * scaleY).rounded(.up) + 1, drawableSize.height)
            scissor = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
    
    /// The pulse origin for the chat seen between `visibleTop` and `visibleBottom` of this view.
    func pulseOrigin(visibleTop: CGFloat, visibleBottom: CGFloat) -> SIMD2<Float> {
        Self.pulseOrigin(canvasSize: viewSize, frame: rect, renderSize: drawableSize, visibleTop: visibleTop, visibleBottom: visibleBottom)
    }
    
    /// `u_origin`: the shaders' default spot taken on the visible chat, the canvas's width from `visibleTop` down to
    /// `visibleBottom`, instead of on the frame, which reaches under the composer and the keyboard. `frame` is the still's
    /// rect in the canvas and `renderSize` is `u_res`; the result is in its pixels from the bottom left.
    static func pulseOrigin(canvasSize: CGSize, frame: CGRect, renderSize: CGSize, visibleTop: CGFloat, visibleBottom: CGFloat) -> SIMD2<Float> {
        guard frame.width > 0, frame.height > 0, renderSize.width >= 1, renderSize.height >= 1 else { return .zero }
        
        // A composer pushed up to the top bar (landscape with the keyboard open) leaves no chat, so the spot sits on the bar's edge.
        let top = min(max(visibleTop, 0), canvasSize.height)
        let bottom = min(max(visibleBottom, top), canvasSize.height)
        let spotX = canvasSize.width * pulseSpot.x
        let spotY = bottom - (bottom - top) * pulseSpot.y
        
        let scaleX = renderSize.width / frame.width
        let scaleY = renderSize.height / frame.height
        return SIMD2(Float((spotX - frame.minX) * scaleX), Float(renderSize.height - (spotY - frame.minY) * scaleY))
    }
    
    /// The visible chat's edges in the canvas, unclamped: below the top bar the canvas's top inset holds, down to the composer's
    /// top edge. Both global tops are in `ChatWallpaperSendPulse.composerTop`'s space; until both are known, the chat ends
    /// above the home indicator.
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
}

extension LiveWallpaperUniforms {
    /// One frame's uniforms in the renderer's layout; a frame that doesn't animate never shows the pulse.
    static func frame(in layout: LiveWallpaperLayout, origin: SIMD2<Float>, isDark: Bool, time: Float, pulse: Float, animates: Bool) -> LiveWallpaperUniforms {
        LiveWallpaperUniforms(res: SIMD2(Float(layout.drawableSize.width), Float(layout.drawableSize.height)),
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
    let globalTop: CGFloat?
    
    func makeUIView(context: Context) -> ChatLiveWallpaperUIView {
        ChatLiveWallpaperUIView(artwork: artwork)
    }
    
    func updateUIView(_ view: ChatLiveWallpaperUIView, context: Context) {
        view.sendPulse = sendPulse
        view.globalTop = globalTop
        view.isDark = isDark
        view.policy = policy
    }
}

/// Holds an `MTKView` in exactly the rect the still is drawn in, so the shader composes the same picture.
private final class ChatLiveWallpaperUIView: UIView, MTKViewDelegate {
    /// How often the view looks for something covering it; presentations and hidden windows have no notification.
    private static let coverCheckInterval: TimeInterval = 0.25
    
    var sendPulse: ChatWallpaperSendPulse?
    /// This view's top edge in the space `sendPulse.composerTop` is reported in.
    var globalTop: CGFloat?
    
    var isDark = false {
        didSet {
            if isDark != oldValue {
                requestPausedFrame()
            }
        }
    }
    
    /// The policy from SwiftUI, which can't see the scene's state or what covers the chat in UIKit.
    var policy = WallpaperMotionPolicy(isOnScreen: false) {
        didSet {
            if policy != oldValue {
                applyMotion()
            }
        }
    }
    
    private let artwork: ChatArtwork
    private let metalView = MTKView()
    private var pipeline: MTLRenderPipelineState?
    private var layout: LiveWallpaperLayout?
    private var clock: LiveWallpaperClock
    private var watchdog = WallpaperFrameWatchdog()
    /// Bumped on every pause, so frames drawn before it are never timed with those after it.
    private var watchdogRun = 0
    /// Tracked here rather than with `scenePhase`, which only a SwiftUI scene keeps up to date.
    private var isSceneActive = false
    private var isCovered = false
    private var coverCheck: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastPulse: Float = 0
    private var hasDrawnFrame = false
    /// Bumped whenever the shown frame is hidden, so a frame drawn before that never shows it again.
    private var frameGeneration = 0
    /// The frame on screen is out of date, and a paused view must draw a new one once the GPU may be used.
    private var needsPausedFrame = true
    
    private var motion: WallpaperMotionPolicy.Motion {
        guard pipeline != nil, !watchdog.hasTripped else { return .still }
        return policy.including(isInWindow: window != nil, isSceneActive: isSceneActive, isCovered: isCovered).motion
    }
    
    /// Where the send pulse starts: on the chat between the top bar and the composer, wherever the keyboard has moved it.
    private var pulseOrigin: SIMD2<Float> {
        guard let layout else { return .zero }
        let chat = LiveWallpaperLayout.visibleChat(canvasHeight: bounds.height,
                                                   canvasGlobalTop: globalTop,
                                                   composerGlobalTop: sendPulse?.composerTop,
                                                   topInset: safeAreaInsets.top,
                                                   bottomInset: safeAreaInsets.bottom,
                                                   windowBottomInset: window?.safeAreaInsets.bottom)
        return layout.pulseOrigin(visibleTop: chat.top, visibleBottom: chat.bottom)
    }
    
    /// Apps must not use the GPU in the background, but an inactive scene (Control Center, the app switcher) still may.
    private var canUseGPU: Bool {
        switch window?.windowScene?.activationState {
        case .foregroundActive, .foregroundInactive: true
        default: false
        }
    }
    
    /// A hidden window (the app lock screen) or anything presented over this view's controller or an ancestor covers the chat.
    private var isCoveredInUIKit: Bool {
        if window?.isHidden == true {
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
    
    init(artwork: ChatArtwork) {
        self.artwork = artwork
        clock = LiveWallpaperClock(stillTime: artwork.stillTime ?? 0)
        super.init(frame: .zero)
        
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        
        metalView.device = LiveWallpaperShader.device
        metalView.colorPixelFormat = LiveWallpaperShader.pixelFormat
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.preferredFramesPerSecond = WallpaperFrameWatchdog.framesPerSecond
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.isUserInteractionEnabled = false
        // Hidden until a frame is ready, so the still shows until then.
        metalView.alpha = 0
        (metalView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalView.delegate = self
        addSubview(metalView)
        
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
        
        Task { [weak self] in
            let pipeline = await LiveWallpaperPipelines.shared.pipeline(for: artwork)
            guard let self, let pipeline else { return }
            self.pipeline = pipeline
            applyMotion()
        }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        let layout = LiveWallpaperLayout(artwork: artwork, viewSize: bounds.size, displayScale: traitCollection.displayScale)
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
    
    // MARK: - MTKViewDelegate
    
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
                                                   isDark: isDark,
                                                   time: clock.time(at: now),
                                                   pulse: sendPulse?.value(at: now) ?? 0,
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
    
    // MARK: - Private
    
    private func applyMotion() {
        updateCoverCheck()
        
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
    
    private func sceneDidChange(_ scene: Any?, isActive: Bool) {
        guard let scene = scene as? UIScene, scene === window?.windowScene, isActive != isSceneActive else { return }
        isSceneActive = isActive
        applyMotion()
    }
    
    /// Asks for a new frame while paused; an animating view draws one anyway.
    private func requestPausedFrame() {
        needsPausedFrame = true
        drawPausedFrameIfNeeded()
    }
    
    private func drawPausedFrameIfNeeded() {
        guard needsPausedFrame, pipeline != nil, metalView.isPaused else { return }
        if canUseGPU {
            metalView.setNeedsDisplay()
        } else {
            // The frame on screen is out of date and can't be redrawn yet, so the still shows until it can.
            hideFrame()
        }
    }
    
    private func hideFrame() {
        frameGeneration += 1
        hasDrawnFrame = false
        metalView.alpha = 0
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
        let isNeeded = pipeline != nil && window != nil && policy.isOnScreen && isSceneActive
        
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
