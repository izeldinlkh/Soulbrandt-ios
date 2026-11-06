import MetalKit
import SwiftUI
import UIKit

/// A small real Metal render loop used to bring up the iOS drawable/pipeline path.
/// The PS3 RSX command stream is not connected to this view yet.
struct MetalRendererView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.035, green: 0.045, blue: 0.065, alpha: 1)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> MetalTriangleRenderer {
        MetalTriangleRenderer()
    }
}

private final class MetalTriangleRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?

    override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        guard let device else { return }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Varying { float4 position [[position]]; float3 color; };
        vertex Varying soulbrandt_vertex(uint id [[vertex_id]]) {
            constexpr float2 p[] = { float2(0.0, 0.72), float2(-0.68, -0.55), float2(0.68, -0.55) };
            constexpr float3 c[] = { float3(0.85, 0.68, 0.34), float3(0.32, 0.55, 0.78), float3(0.72, 0.28, 0.24) };
            Varying out; out.position = float4(p[id], 0.0, 1.0); out.color = c[id]; return out;
        }
        fragment float4 soulbrandt_fragment(Varying in [[stage_in]]) {
            return float4(in.color, 1.0);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let vertex = library.makeFunction(name: "soulbrandt_vertex"),
                  let fragment = library.makeFunction(name: "soulbrandt_fragment") else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            pipeline = nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
