import ISOCore
import MetalKit
import SwiftUI

struct PreviewUniforms {
    var scale: SIMD2<Float>
    var width: Int32
    var height: Int32
    var layout: Int32
}

/// One tile's video surface. Rendering runs at a fixed preview rate, independent of capture.
struct MetalPreviewView: NSViewRepresentable {
    let store: PreviewFrameStore

    func makeCoordinator() -> PreviewRenderer {
        PreviewRenderer(store: store)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: PreviewRenderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

final class PreviewRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()!
    private static let queue = device.makeCommandQueue()!
    private static let pipeline: MTLRenderPipelineState = {
        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try! device.makeRenderPipelineState(descriptor: descriptor)
    }()

    private let store: PreviewFrameStore
    private var texture: MTLTexture?
    private var format: VideoFormat?

    init(store: PreviewFrameStore) {
        self.store = store
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        store.consume { format, bytes in upload(format: format, bytes: bytes) }

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commands = Self.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        if let texture, let format {
            var uniforms = PreviewUniforms(
                scale: Self.fitScale(video: format, drawable: view.drawableSize),
                width: Int32(format.width),
                height: Int32(format.height),
                layout: format.pixelLayout == .v210 ? 1 : 0
            )
            encoder.setRenderPipelineState(Self.pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private func upload(format: VideoFormat, bytes: UnsafeRawPointer) {
        let isV210 = format.pixelLayout == .v210
        let wordsPerRow = format.rowBytes / 4
        if texture == nil || self.format != format {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: isV210 ? .rgb10a2Uint : .rgba8Uint,
                width: wordsPerRow,
                height: format.height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            texture = Self.device.makeTexture(descriptor: descriptor)
            self.format = format
        }
        texture?.replace(
            region: MTLRegionMake2D(0, 0, wordsPerRow, format.height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: format.rowBytes
        )
    }

    private static func fitScale(video: VideoFormat, drawable: CGSize) -> SIMD2<Float> {
        guard drawable.width > 0, drawable.height > 0 else { return SIMD2(1, 1) }
        let videoAspect = Double(video.width) / Double(video.height)
        let viewAspect = drawable.width / drawable.height
        return viewAspect > videoAspect
            ? SIMD2(Float(videoAspect / viewAspect), 1)
            : SIMD2(1, Float(viewAspect / videoAspect))
    }
}
