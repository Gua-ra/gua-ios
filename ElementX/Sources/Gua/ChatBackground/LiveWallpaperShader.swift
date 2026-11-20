//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Metal

/// `GuaWallpaperUniforms` in the generated `.msl` files, 40 bytes at fragment buffer 0.
nonisolated struct LiveWallpaperUniforms {
    var res: SIMD2<Float>
    var tilt: SIMD2<Float> = .zero
    /// Zero means the shader's own spot near the newest outgoing bubble.
    var origin: SIMD2<Float> = .zero
    var time: Float
    var dark: Float
    var pulse: Float
    var pad: Float = 0
}

/// Compiles the live artworks' Metal source at runtime and draws them.
nonisolated enum LiveWallpaperShader {
    enum Failure: Error {
        case noMetalDevice
        case missingSource(String)
        case missingFunction(String)
    }
    
    /// 8-bit and not sRGB, so the values are stored as the shader computes them, as in WebGL.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let device = MTLCreateSystemDefaultDevice()
    static let commandQueue = device?.makeCommandQueue()
    
    /// Metal compiles on its own threads, so awaiting this holds no thread for the length of the compile.
    @concurrent static func makePipeline(for artwork: ChatArtwork, device: MTLDevice) async throws -> MTLRenderPipelineState {
        guard let file = artwork.shaderFileName, let url = ChatArtworkLoader.url(for: file) else {
            throw Failure.missingSource(artwork.id)
        }
        
        let options = MTLCompileOptions()
        // Fast math moves some pixels by up to 13 levels from the goldens the shaders were checked against.
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try await device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = artwork.id
        descriptor.vertexFunction = library.makeFunction(name: "gua_wallpaper_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gua_wallpaper_fragment")
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
            throw Failure.missingFunction(artwork.id)
        }
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try await device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    /// Draws one full-screen triangle, shading only `scissor` when it is given.
    static func encode(_ pipeline: MTLRenderPipelineState,
                       uniforms: LiveWallpaperUniforms,
                       pass: MTLRenderPassDescriptor,
                       scissor: MTLScissorRect? = nil,
                       into commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        if let scissor {
            encoder.setScissorRect(scissor)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LiveWallpaperUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

/// Each artwork's pipeline, compiled once off the main thread and kept for the life of the app.
final class LiveWallpaperPipelines {
    static let shared = LiveWallpaperPipelines()
    
    private var pipelines: [ChatArtwork: Task<MTLRenderPipelineState?, Never>] = [:]
    private var hasLoggedMissingDevice = false
    
    func pipeline(for artwork: ChatArtwork) async -> MTLRenderPipelineState? {
        if let pipeline = pipelines[artwork] {
            return await pipeline.value
        }
        
        guard let device = LiveWallpaperShader.device, LiveWallpaperShader.commandQueue != nil else {
            if !hasLoggedMissingDevice {
                hasLoggedMissingDevice = true
                MXLog.error("Live wallpapers show their stills: \(LiveWallpaperShader.Failure.noMetalDevice)")
            }
            LiveWallpaperConditions.shared.reportUnavailable(artwork)
            return nil
        }
        
        let pipeline = Task(priority: .userInitiated) { () -> MTLRenderPipelineState? in
            do {
                return try await LiveWallpaperShader.makePipeline(for: artwork, device: device)
            } catch {
                MXLog.error("The live wallpaper \(artwork.id) shows its still: \(error)")
                LiveWallpaperConditions.shared.reportUnavailable(artwork)
                return nil
            }
        }
        pipelines[artwork] = pipeline
        return await pipeline.value
    }
}
