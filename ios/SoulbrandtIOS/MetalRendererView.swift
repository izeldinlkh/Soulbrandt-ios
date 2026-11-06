import MetalKit
import QuartzCore
import SwiftUI

/// Native GPU surface used as the eventual RSX presentation target.
/// The current draw workload is deliberately a diagnostic scene, not game rendering.
struct MetalRendererView: View {
    @State private var diagnostics = "Initializing GPU…"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MetalRenderSurface { message in
                diagnostics = message
            }
            Text(diagnostics)
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
    let diagnosticsChanged: (String) -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        // Match the pinned RSX backend's initial 1280x720 depth target.
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1280, height: 720)
        view.presentsWithTransaction = false
        view.clearColor = MTLClearColor(red: 0.035, green: 0.045, blue: 0.065, alpha: 1)
        view.delegate = context.coordinator.renderer
        if let layer = view.layer as? CAMetalLayer {
            // The MTKView owns this layer. The C bridge publishes a non-owning
            // pointer for the eventual rsx_metal_backend_set_layer() call.
            soulbrandt_metal_layer_set(Unmanaged.passUnretained(layer).toOpaque())
        } else {
            diagnosticsChanged("MTKView did not provide a CAMetalLayer")
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        if let layer = uiView.layer as? CAMetalLayer {
            soulbrandt_metal_layer_clear(Unmanaged.passUnretained(layer).toOpaque())
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(diagnosticsChanged: diagnosticsChanged)
    }

    final class Coordinator {
        let renderer: MetalTriangleRenderer

        init(diagnosticsChanged: @escaping (String) -> Void) {
            renderer = MetalTriangleRenderer(diagnosticsChanged: diagnosticsChanged)
        }
    }
}

private final class MetalTriangleRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let diagnosticsChanged: (String) -> Void
    private var metal4Renderer: AnyObject?
    private var lastDiagnosticsTime = CACurrentMediaTime()
    private var framesSinceDiagnostics = 0
    private var reportedInitializationFailure = false
    private let metal4Available: Bool

    init(diagnosticsChanged: @escaping (String) -> Void) {
        let selectedDevice = MTLCreateSystemDefaultDevice()
        device = selectedDevice
        queue = selectedDevice?.makeCommandQueue()
        self.diagnosticsChanged = diagnosticsChanged

        var selectedMetal4Renderer: AnyObject?
        if #available(iOS 26.0, *), let selectedDevice,
           selectedDevice.supportsFamily(.metal4) {
            selectedMetal4Renderer = Metal4RendererState(device: selectedDevice)
        }
        metal4Renderer = selectedMetal4Renderer
        metal4Available = selectedMetal4Renderer != nil

        super.init()
        buildPipeline()
        reportInitialStatus()
    }

    private func publishDiagnostics(_ message: String) {
        DispatchQueue.main.async { [diagnosticsChanged] in
            diagnosticsChanged(message)
        }
    }

    private func reportInitialStatus() {
        guard let device else {
            publishDiagnostics("Metal GPU unavailable")
            return
        }
        let api = metal4Available ? "Metal 4 active" : "Metal 3-compatible fallback"
        let queueStatus = queue == nil ? " • command queue failed" : ""
        diagnosticsChanged("\(device.name) • \(api)\(queueStatus)")
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
                  let fragment = library.makeFunction(name: "soulbrandt_fragment") else {
                publishDiagnostics("Metal shader functions missing")
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Soulbrandt diagnostic pipeline"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            diagnosticsChanged("Metal pipeline error: \(error.localizedDescription)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline else { return }

        if #available(iOS 26.0, *),
           let metal4 = metal4Renderer as? Metal4RendererState {
            guard metal4.draw(in: view, pipeline: pipeline) else {
                publishDiagnostics("Metal 4 frame submission failed or timed out")
                return
            }
            updateFrameDiagnostics(backend: "Metal 4")
            return
        }

        guard let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            if !reportedInitializationFailure {
                reportedInitializationFailure = true
                publishDiagnostics("Renderer could not acquire a drawable or command buffer")
            }
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        updateFrameDiagnostics(backend: "Metal 3 fallback")
    }

    private func updateFrameDiagnostics(backend: String) {
        framesSinceDiagnostics += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastDiagnosticsTime
        guard elapsed >= 1 else { return }
        let fps = Double(framesSinceDiagnostics) / elapsed
        publishDiagnostics(String(format: "%@ • %.1f FPS", backend, fps))
        framesSinceDiagnostics = 0
        lastDiagnosticsTime = now
    }
}
