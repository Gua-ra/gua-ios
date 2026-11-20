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
    
    static func value(secondsSinceSend seconds: TimeInterval) -> Double {
        guard seconds >= 0, seconds <= duration else { return 0 }
        let rising = min(1, seconds / rise)
        return rising * rising * (3 - 2 * rising) * exp(-max(0, seconds - rise) / decay)
    }
    
    /// When the pulse of a send at `time` starts: during a pulse, where its rising edge has the current value, so a send
    /// never snaps the pulse back to zero.
    static func start(ofSendAt time: TimeInterval, currentStart: TimeInterval?) -> TimeInterval {
        let current = currentStart.map { value(secondsSinceSend: time - $0) } ?? 0
        // The inverse of the rising edge's smoothstep.
        return time - rise * (0.5 - sin(asin(1 - 2 * current) / 3))
    }
}

/// The send pulse of one chat's live wallpaper, from the events the user sends from this device, and where the chat ends
/// above the composer, which places it.
final class ChatWallpaperSendPulse {
    private static var rooms: [String: ChatWallpaperSendPulse] = [:]
    
    private let now: () -> TimeInterval
    /// When the pulse that plays now started: the last send, or earlier when that send came during a pulse.
    private(set) var pulseStart: TimeInterval?
    /// The top edge of the composer, or of the theme preview's controls, in SwiftUI's global space.
    var composerTop: CGFloat?
    /// The transaction IDs of every local echo the room's timeline has shown.
    private var seenLocalEchoes: Set<String> = []
    /// Set while the timeline on screen is opening: its local echoes were sent before it opened.
    private var isOpeningTimeline = true
    
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
    
    /// Reads an update of a room's own timeline: a thread, the pinned events or the media don't show the room's wallpaper.
    static func recordLocalEchoes(in items: [RoomTimelineItemProtocol], isSwitchingTimelines: Bool, roomID: String, timelineKind: TimelineKind) {
        switch timelineKind {
        case .live, .detached:
            forRoom(roomID).recordLocalEchoes(in: items, isSwitchingTimelines: isSwitchingTimelines)
        case .pinned, .thread, .media:
            break
        }
    }
    
    /// Pulses when the update shows a local echo of the user's own event that wasn't in the timeline when it opened.
    ///
    /// Only this device's send queue makes local echoes, one per new event: history, edits, reactions and redactions
    /// add none, and events from the user's other devices arrive with an event ID instead of a transaction ID.
    /// The echo keeps its transaction ID until its remote echo replaces it, so each send counts once.
    /// A timeline that opens, or switches between live and an event, starts at its still with no pulse.
    func recordLocalEchoes(in items: [RoomTimelineItemProtocol], isSwitchingTimelines: Bool) {
        if isSwitchingTimelines {
            isOpeningTimeline = true
            pulseStart = nil
        }
        
        var hasNewLocalEcho = false
        for case let item as EventBasedTimelineItemProtocol in items where item.isOutgoing {
            if let transactionID = item.id.transactionID, seenLocalEchoes.insert(transactionID).inserted {
                hasNewLocalEcho = true
            }
        }
        
        if isOpeningTimeline {
            // A timeline can open before it has loaded, so the opening lasts until an update holds events.
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
