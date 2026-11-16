//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import QuartzCore

/// The shader's `u_time`: the artwork's still time plus the seconds it has animated, so its first frame is the still.
nonisolated struct LiveWallpaperClock {
    /// Keeps the float time small enough that it never loses precision.
    static let period: TimeInterval = 1800
    
    let stillTime: TimeInterval
    private var elapsed: TimeInterval = 0
    private var runningSince: TimeInterval?
    
    var isRunning: Bool {
        runningSince != nil
    }
    
    init(stillTime: TimeInterval) {
        self.stillTime = stillTime
    }
    
    mutating func start(at time: TimeInterval) {
        guard runningSince == nil else { return }
        runningSince = time
    }
    
    mutating func pause(at time: TimeInterval) {
        guard let runningSince else { return }
        elapsed += max(0, time - runningSince)
        self.runningSince = nil
    }
    
    func time(at time: TimeInterval) -> Float {
        let running = runningSince.map { max(0, time - $0) } ?? 0
        return Float((stillTime + elapsed + running).truncatingRemainder(dividingBy: Self.period))
    }
}

/// The send pulse the Lab plays for its "Send a message" button.
nonisolated enum LiveWallpaperPulse {
    static let rise: TimeInterval = 0.25
    static let decay: TimeInterval = 0.9
    static let duration: TimeInterval = 4.2
    
    static func value(secondsSinceSend seconds: TimeInterval) -> Float {
        guard seconds >= 0, seconds <= duration else { return 0 }
        let rising = min(1, seconds / rise)
        return Float(rising * rising * (3 - 2 * rising) * exp(-max(0, seconds - rise) / decay))
    }
}

/// When the user last sent a message from this device in one chat, which its live wallpaper turns into the send pulse.
final class ChatWallpaperSendPulse {
    private static var rooms: [String: ChatWallpaperSendPulse] = [:]
    
    private let now: () -> TimeInterval
    private(set) var lastSend: TimeInterval?
    
    /// Times use `CACurrentMediaTime`, the clock the renderer draws with.
    init(now: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.now = now
    }
    
    static func forRoom(_ roomID: String) -> ChatWallpaperSendPulse {
        if let pulse = rooms[roomID] {
            return pulse
        }
        let pulse = ChatWallpaperSendPulse()
        rooms[roomID] = pulse
        return pulse
    }
    
    /// Records a send from a room's own timeline: a thread or the pinned events don't show the room's wallpaper.
    static func recordOwnSend(inRoom roomID: String, timelineKind: TimelineKind) {
        switch timelineKind {
        case .live, .detached:
            forRoom(roomID).recordSend()
        case .pinned, .thread, .media:
            break
        }
    }
    
    func recordSend() {
        lastSend = now()
    }
    
    func value(at time: TimeInterval) -> Float {
        guard let lastSend else { return 0 }
        return LiveWallpaperPulse.value(secondsSinceSend: time - lastSend)
    }
}
