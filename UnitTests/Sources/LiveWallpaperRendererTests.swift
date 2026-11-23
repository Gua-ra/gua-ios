//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import ImageIO
import Metal
import Testing

@Suite(.enabled(if: LiveWallpaperShader.device != nil, "The simulator has no Metal device, so the live wallpapers can't be drawn."))
final class LiveWallpaperRendererTests {
    /// A fifth of the stills' size, which keeps their shape.
    private static let width = 258
    private static let height = 559
    
    @Test
    func uniformsMatchTheShaders() {
        #expect(MemoryLayout<LiveWallpaperUniforms>.stride == 40)
        #expect(MemoryLayout<LiveWallpaperUniforms>.offset(of: \.res) == 0)
        #expect(MemoryLayout<LiveWallpaperUniforms>.offset(of: \.tilt) == 8)
        #expect(MemoryLayout<LiveWallpaperUniforms>.offset(of: \.origin) == 16)
        #expect(MemoryLayout<LiveWallpaperUniforms>.offset(of: \.time) == 24)
        #expect(MemoryLayout<LiveWallpaperUniforms>.offset(of: \.dark) == 28)
        #expect(MemoryLayout<LiveWallpaperUniforms>.offset(of: \.pulse) == 32)
    }
    
    @Test(arguments: ChatArtwork.allCases.filter(\.isLive))
    func liveArtworkRendersItsStillThenMoves(_ artwork: ChatArtwork) async throws {
        let stillTime = try #require(artwork.stillTime.map(Float.init))
        let pipeline = try #require(await LiveWallpaperPipelines.shared.pipeline(for: artwork))
        
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let still = try render(pipeline, time: stillTime, dark: dark, pulse: 0)
            #expect(try render(pipeline, time: stillTime, dark: dark, pulse: 0) == still, "\(artwork.id) \(appearance) draws the same frame twice")
            
            let difference = try meanDifference(still, stillImage(of: artwork, dark: dark))
            #expect(difference < 3, "\(artwork.id) \(appearance) differs from its still by \(difference) levels")
            #expect(try difference < meanDifference(still, stillImage(of: artwork, dark: !dark)), "\(artwork.id) \(appearance) draws the other appearance")
            
            let later = try render(pipeline, time: stillTime + 1, dark: dark, pulse: 0)
            #expect(changedShare(still, later) > 0.01, "\(artwork.id) \(appearance) doesn't move within a second")
            
            let pulsed = try render(pipeline, time: stillTime, dark: dark, pulse: 0.6)
            #expect(changedShare(still, pulsed) > 0.05, "\(artwork.id) \(appearance) doesn't show the send pulse")
        }
    }
    
    @Test(arguments: ChatArtwork.allCases.filter(\.isLive))
    func pulseOriginIsInTheShadersPixelSpace(_ artwork: ChatArtwork) async throws {
        let stillTime = try #require(artwork.stillTime.map(Float.init))
        let pipeline = try #require(await LiveWallpaperPipelines.shared.pipeline(for: artwork))
        let layout = LiveWallpaperLayout(artwork: artwork, viewSize: CGSize(width: Self.width, height: Self.height), displayScale: 2)
        try #require(layout.drawableSize == CGSize(width: Self.width, height: Self.height))
        let origin = layout.pulseOrigin(visibleTop: 0, visibleBottom: CGFloat(Self.height))
        
        let shadersOwnSpot = try render(pipeline, time: stillTime, dark: false, pulse: 0.6)
        let layoutSpot = try render(pipeline, time: stillTime, dark: false, pulse: 0.6, origin: origin)
        let upsideDown = try render(pipeline, time: stillTime, dark: false, pulse: 0.6, origin: SIMD2(origin.x, Float(Self.height) - origin.y))
        
        // A fully visible view shaped like the still puts the spot at the shaders' default.
        #expect(meanDifference(shadersOwnSpot, layoutSpot) < 0.1, "\(artwork.id) moves the pulse")
        #expect(changedShare(shadersOwnSpot, layoutSpot) < 0.01, "\(artwork.id) moves the pulse")
        #expect(changedShare(shadersOwnSpot, upsideDown) > 0.02, "\(artwork.id) ignores the pulse origin")
    }
    
    @Test
    func pipelinesAreCompiledOnce() async throws {
        let first = try #require(await LiveWallpaperPipelines.shared.pipeline(for: .silk))
        let second = try #require(await LiveWallpaperPipelines.shared.pipeline(for: .silk))
        #expect(first === second)
    }
    
    /// Read back through a buffer, which the simulator needs.
    private func render(_ pipeline: MTLRenderPipelineState, time: Float, dark: Bool, pulse: Float, origin: SIMD2<Float> = .zero) throws -> [UInt8] {
        let device = try #require(LiveWallpaperShader.device)
        let queue = try #require(LiveWallpaperShader.commandQueue)
        let width = Self.width, height = Self.height, bytesPerRow = Self.width * 4
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LiveWallpaperShader.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let buffer = try #require(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        
        let commandBuffer = try #require(queue.makeCommandBuffer())
        LiveWallpaperShader.encode(pipeline,
                                   uniforms: LiveWallpaperUniforms(res: SIMD2(Float(width), Float(height)), origin: origin, time: time, dark: dark ? 1 : 0, pulse: pulse),
                                   pass: pass,
                                   into: commandBuffer)
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.error == nil)
        
        // BGRA to RGBA, so frames compare with images directly.
        let bgra = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height)
        var rgba = [UInt8](repeating: 255, count: bytesPerRow * height)
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            rgba[pixel] = bgra[pixel + 2]
            rgba[pixel + 1] = bgra[pixel + 1]
            rgba[pixel + 2] = bgra[pixel]
        }
        return rgba
    }
    
    private func stillImage(of artwork: ChatArtwork, dark: Bool) throws -> [UInt8] {
        let url = try #require(ChatArtworkLoader.url(for: dark ? artwork.fileNames.dark : artwork.fileNames.light))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Self.height] as CFDictionary
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options))
        
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        }
        return pixels
    }
    
    /// The share of pixels with a colour channel more than 2 levels apart, which dithering alone never reaches.
    private func changedShare(_ first: [UInt8], _ second: [UInt8]) -> Double {
        var changed = 0
        for pixel in stride(from: 0, to: min(first.count, second.count), by: 4) where (0..<3).contains(where: { abs(Int(first[pixel + $0]) - Int(second[pixel + $0])) > 2 }) {
            changed += 1
        }
        return Double(changed) / Double(first.count / 4)
    }
    
    private func meanDifference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        var total = 0
        for pixel in stride(from: 0, to: min(first.count, second.count), by: 4) {
            for channel in 0..<3 {
                total += abs(Int(first[pixel + channel]) - Int(second[pixel + channel]))
            }
        }
        return Double(total) / Double(first.count / 4 * 3)
    }
}
