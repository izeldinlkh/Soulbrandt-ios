import Metal
import MetalKit
import QuartzCore
import SwiftUI

/// A real on-device Metal presentation test while the PS3 runtime is not yet
/// linked. It deliberately uses MTKView's drawable loop only for this preview.
/// When the RSX runtime is started, this view must hand drawable ownership to
/// the upstream RSX backend instead of running a second renderer.
struct MetalRendererView: View {
    @State private var status = "Preparing Metal preview…"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MetalRenderSurface { message in
                status = message
            }
            Text(status)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
                .allowsHitTesting(false)
        }
    }
}

private struct MetalRenderSurface: UIViewRepresentable {
    let statusChanged: (String) -> Void

    final class Coordinator {
        var renderer: MetalPreviewRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let view = MTKView(frame: .zero, device: nil)
            statusChanged("Metal GPU unavailable")
            return view
        }

        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1280, height: 720)
        view.presentsWithTransaction = false
        view.clearColor = MTLClearColor(red: 0.025, green: 0.035, blue: 0.06, alpha: 1)

        guard let layer = view.layer as? CAMetalLayer else {
            view.isPaused = true
            statusChanged("CAMetalLayer unavailable")
            return view
        }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        soulbrandt_metal_layer_set(Unmanaged.passUnretained(layer).toOpaque())

        guard let renderer = MetalPreviewRenderer(device: device, statusChanged: statusChanged) else {
            view.isPaused = true
            statusChanged("Metal pipeline creation failed")
            return view
        }

        context.coordinator.renderer = renderer
        view.delegate = renderer
        statusChanged("\(device.name) • Metal pipeline ready • presenting diagnostic frames")
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // The preview renderer owns this MTKView loop until the RSX runtime
        // replaces it with direct CAMetalLayer drawable submission.
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.isPaused = true
        uiView.delegate = nil
        soulbrandt_runtime_shutdown()
        if let layer = uiView.layer as? CAMetalLayer {
            soulbrandt_metal_layer_clear(Unmanaged.passUnretained(layer).toOpaque())
        }
        coordinator.renderer = nil
    }
}

/// Small animated triangle used to prove that command encoding, drawable
/// acquisition, presentation and frame pacing all work on the target iPhone.
/// This is intentionally not presented as a PS3/RSX frame.
private final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let startedAt = CACurrentMediaTime()
    private let statusChanged: (String) -> Void
    private var fpsWindowStart = CACurrentMediaTime()
    private var framesInWindow = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PreviewVertex {
        float4 position [[position]];
        float4 color;
    };

    vertex PreviewVertex preview_vertex(
        uint vertexID [[vertex_id]],
        constant float &elapsed [[buffer(0)]])
    {
        const float2 positions[3] = {
            float2(0.0, 0.72),
            float2(-0.64, -0.54),
            float2(0.64, -0.54)
        };
        const float3 colors[3] = {
            float3(0.20, 0.78, 1.00),
            float3(0.92, 0.38, 0.68),
            float3(1.00, 0.76, 0.24)
        };

        float angle = elapsed * 0.45;
        float2 p = positions[vertexID];
        float2 rotated = float2(
            p.x * cos(angle) - p.y * sin(angle),
            p.x * sin(angle) + p.y * cos(angle));
        PreviewVertex out;
        out.position = float4(rotated, 0.0, 1.0);
        out.color = float4(colors[vertexID], 1.0);
        return out;
    }

    fragment float4 preview_fragment(PreviewVertex in [[stage_in]])
    {
        return in.color;
    }
    """

    init?(device: MTLDevice, statusChanged: @escaping (String) -> Void) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "preview_vertex"),
              let fragment = library.makeFunction(name: "preview_fragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Soulbrandt Metal bring-up preview"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.commandQueue = queue
        self.pipeline = pipeline
        self.statusChanged = statusChanged
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Fixed 1280x720 guest-style surface for the bring-up preview.
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            guard let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                return
            }

            var elapsed = Float(CACurrentMediaTime() - startedAt)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&elapsed, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()

            framesInWindow += 1
            let now = CACurrentMediaTime()
            let duration = now - fpsWindowStart
            if duration >= 1.0 {
                let fps = Double(framesInWindow) / duration
                framesInWindow = 0
                fpsWindowStart = now
                let message = String(format: "Metal live • %.0f FPS • synthetic test frame", fps)
                DispatchQueue.main.async { [statusChanged] in
                    statusChanged(message)
                }
            }
        }
    }
}
