//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import QuartzCore

/// The shader's `u_time`: the still time plus the seconds spent animating.
nonisolated struct LiveWallpaperClock {
    /// Wraps the time so the Float keeps millisecond precision.
    static let period: TimeInterval = 1800
    
    let stillTime: TimeInterval
    private var elapsed: TimeInterval = 0
    private var runningSince: TimeInterval?
    
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

/// The send pulse envelope from the Wallpaper Lab.
nonisolated enum LiveWallpaperPulse {
    static let rise: TimeInterval = 0.25
    static let decay: TimeInterval = 0.9
    static let duration: TimeInterval = 4.2
    
    static func value(secondsSinceSend seconds: TimeInterval) -> Double {
        guard seconds >= 0, seconds <= duration else { return 0 }
        let rising = min(1, seconds / rise)
        return rising * rising * (3 - 2 * rising) * exp(-max(0, seconds - rise) / decay)
    }
    
    /// A send during a pulse starts where the rising edge has the current value, so the pulse never snaps back to zero.
    static func start(ofSendAt time: TimeInterval, currentStart: TimeInterval?) -> TimeInterval {
        let current = currentStart.map { value(secondsSinceSend: time - $0) } ?? 0
        // The inverse of the rising edge's smoothstep.
        return time - rise * (0.5 - sin(asin(1 - 2 * current) / 3))
    }
}

/// A chat's send pulse, from sends on this device, placed above the composer.
final class ChatWallpaperSendPulse {
    private static var rooms: [String: ChatWallpaperSendPulse] = [:]
    
    private let now: () -> TimeInterval
    /// The last send, or earlier when that send came during a pulse.
    private(set) var pulseStart: TimeInterval?
    /// The top edge of the composer, or of the theme preview's controls, in SwiftUI's global space.
    var composerTop: CGFloat?
    private var seenTransactionIDs: Set<String> = []
    /// Local echoes seen while the timeline opens were sent before it opened.
    private var isOpeningTimeline = true
    
    /// `now` must be the clock the renderer draws with.
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
    
    /// Threads, pinned events and the media browser don't show the room's wallpaper, so they never pulse it.
    static func recordLocalEchoes(in items: [RoomTimelineItemProtocol], isSwitchingTimelines: Bool, roomID: String, timelineKind: TimelineKind) {
        switch timelineKind {
        case .live, .detached:
            forRoom(roomID).recordLocalEchoes(in: items, isSwitchingTimelines: isSwitchingTimelines)
        case .pinned, .thread, .media:
            break
        }
    }
    
    /// Pulses for each local echo first seen after the timeline opened. Only this device's send queue creates local
    /// echoes, one per new event, so history, edits, reactions and the user's other devices never pulse.
    func recordLocalEchoes(in items: [RoomTimelineItemProtocol], isSwitchingTimelines: Bool) {
        if isSwitchingTimelines {
            isOpeningTimeline = true
            pulseStart = nil
        }
        
        var hasNewLocalEcho = false
        for case let item as EventBasedTimelineItemProtocol in items where item.isOutgoing {
            if let transactionID = item.id.transactionID, seenTransactionIDs.insert(transactionID).inserted {
                hasNewLocalEcho = true
            }
        }
        
        if isOpeningTimeline {
            // A timeline can open empty, so opening lasts until an update holds events.
            isOpeningTimeline = !items.contains { $0 is EventBasedTimelineItemProtocol || $0 is CollapsibleTimelineItem }
        } else if hasNewLocalEcho {
            recordSend()
        }
    }
    
    func recordSend() {
        pulseStart = LiveWallpaperPulse.start(ofSendAt: now(), currentStart: pulseStart)
    }
    
    func value(at time: TimeInterval) -> Double {
        guard let pulseStart else { return 0 }
        return LiveWallpaperPulse.value(secondsSinceSend: time - pulseStart)
    }
}
