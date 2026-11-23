//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import SwiftUI
import Testing

/// `live-wallpaper-motion-fixtures.json` is shared with Android.
final class LiveWallpaperMotionFixtureTests {
    private let fixtures: MotionFixtures
    
    init() throws {
        let url = try #require(Bundle(for: Self.self).url(forResource: "live-wallpaper-motion-fixtures.json", withExtension: nil))
        fixtures = try JSONDecoder().decode(MotionFixtures.self, from: Data(contentsOf: url))
    }
    
    @Test
    func tiltFollowsTheFixtures() throws {
        #expect(fixtures.tilt.maxAngleDegrees == WallpaperTiltTracker.maxAngleDegrees)
        #expect(fixtures.tilt.recentreSeconds == WallpaperTiltTracker.recentreSeconds)
        #expect(fixtures.tilt.smoothingSeconds == WallpaperTiltTracker.smoothingSeconds)
        #expect(fixtures.tilt.maxStepSeconds == WallpaperTiltTracker.maxStepSeconds)
        #expect(!fixtures.tilt.cases.isEmpty)
        
        for fixture in fixtures.tilt.cases {
            var tracker = WallpaperTiltTracker()
            var tilts: [(time: Double, tilt: SIMD2<Double>)] = []
            
            for event in fixture.events {
                if event.stop == true {
                    tracker.stop()
                    continue
                }
                let time = try #require(event.t, "\(fixture.name)")
                let rate = try #require(event.rate, "\(fixture.name)")
                tilts.append((time, tracker.sample(rate: SIMD3(rate[0], rate[1], rate[2]), at: time)))
            }
            
            try #require(tilts.count == fixture.expected.count, "\(fixture.name)")
            for ((time, tilt), expected) in zip(tilts, fixture.expected) {
                #expect(abs(tilt.x - expected[0]) < 1e-9 && abs(tilt.y - expected[1]) < 1e-9, "\(fixture.name) at \(time): \(tilt) instead of \(expected)")
            }
        }
    }
    
    @Test
    func interfaceRotationFollowsTheFixtures() throws {
        #expect(fixtures.interface.map(\.rotation) == [0, 90, 180, 270])
        
        for fixture in fixtures.interface {
            let rotation = try #require(WallpaperScreenRotation(rawValue: fixture.rotation))
            let tilt = rotation.interfaceTilt(SIMD2(fixture.device[0], fixture.device[1]))
            #expect(abs(tilt.x - fixture.expected[0]) < 1e-9 && abs(tilt.y - fixture.expected[1]) < 1e-9, "\(fixture.rotation)")
        }
    }
    
    @Test
    func stillRectFollowsTheFixtures() {
        #expect(CGSize(width: fixtures.still.width, height: fixtures.still.height) == ChatArtwork.pixelSize)
        #expect(fixtures.still.shiftShare == WallpaperStillLayout.shiftShare)
        #expect(!fixtures.still.cases.isEmpty)
        
        for fixture in fixtures.still.cases {
            let layout = WallpaperStillLayout(viewSize: CGSize(width: fixture.view[0], height: fixture.view[1]))
            let rect = layout.imageRect(anchor: UnitPoint(x: fixture.anchor[0], y: fixture.anchor[1]), at: SIMD2(fixture.tilt[0], fixture.tilt[1]))
            let values = [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }
            let name = "view \(fixture.view), anchor \(fixture.anchor), tilt \(fixture.tilt)"
            
            #expect(abs(Double(layout.shift) - fixture.expected.shift) < 1e-6, "\(name)")
            #expect(zip(values, fixture.expected.rect).allSatisfy { abs($0 - $1) < 1e-6 }, "\(name): \(values) instead of \(fixture.expected.rect)")
        }
    }
    
    @Test
    func pulseFollowsTheFixtures() {
        #expect(fixtures.pulse.rise == LiveWallpaperPulse.rise)
        #expect(fixtures.pulse.decay == LiveWallpaperPulse.decay)
        #expect(fixtures.pulse.end == LiveWallpaperPulse.duration)
        #expect(!fixtures.pulse.cases.isEmpty)
        
        for fixture in fixtures.pulse.cases {
            var now = 0.0
            let pulse = ChatWallpaperSendPulse { now }
            var sends = fixture.sends[...]
            
            for sample in fixture.samples {
                let (time, expected) = (sample[0], sample[1])
                while let send = sends.first, send <= time {
                    now = send
                    pulse.recordSend()
                    sends.removeFirst()
                }
                #expect(abs(pulse.value(at: time) - expected) < 1e-9, "\(fixture.name) at \(time)")
            }
        }
    }
}

private struct MotionFixtures: Decodable {
    struct Tilt: Decodable {
        let maxAngleDegrees: Double
        let recentreSeconds: Double
        let smoothingSeconds: Double
        let maxStepSeconds: Double
        let cases: [TiltCase]
    }
    
    struct TiltCase: Decodable {
        let name: String
        let events: [TiltEvent]
        let expected: [[Double]]
    }
    
    /// A gyroscope sample, or a stop.
    struct TiltEvent: Decodable {
        let t: Double?
        let rate: [Double]?
        let stop: Bool?
    }
    
    struct InterfaceCase: Decodable {
        let rotation: Int
        let device: [Double]
        let expected: [Double]
    }
    
    struct Still: Decodable {
        let width: Double
        let height: Double
        let shiftShare: Double
        let cases: [StillCase]
    }
    
    struct StillCase: Decodable {
        struct Expected: Decodable {
            let shift: Double
            /// x, y, width and height.
            let rect: [Double]
        }
        
        let view: [Double]
        let anchor: [Double]
        let tilt: [Double]
        let expected: Expected
    }
    
    struct Pulse: Decodable {
        let rise: Double
        let decay: Double
        let end: Double
        let cases: [PulseCase]
    }
    
    struct PulseCase: Decodable {
        let name: String
        let sends: [Double]
        /// Pairs of time and expected value.
        let samples: [[Double]]
    }
    
    let tilt: Tilt
    let interface: [InterfaceCase]
    let still: Still
    let pulse: Pulse
}
