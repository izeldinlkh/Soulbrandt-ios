import Metal
import MetalKit
import QuartzCore
import SwiftUI

/// Owns the drawable surface that the PS3 RSX Metal backend will present into.
///
/// Do not attach an MTKView draw delegate here: the RSX backend obtains
/// CAMetalLayer.nextDrawable() itself and submits the actual guest frame. A
/// second MTKView render loop would compete for the same drawable queue.
struct MetalRendererView: View {
    @State private var status = "Preparing Metal surface…"

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

    func makeUIView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = nil
        view.framebufferOnly = true
        // Let the RSX backend control the native render resolution.
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1280, height: 720)
        view.presentsWithTransaction = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let device else {
            statusChanged("Metal GPU unavailable")
            return view
        }
        guard let layer = view.layer as? CAMetalLayer else {
            statusChanged("CAMetalLayer unavailable")
            return view
        }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        soulbrandt_metal_layer_set(Unmanaged.passUnretained(layer).toOpaque())

        let runtimeResult = soulbrandt_runtime_prepare()
        if runtimeResult == 0 {
            statusChanged("\(device.name) • RSX Metal backend initialized • cellPad HLE ready")
        } else {
            statusChanged("\(device.name) • Metal layer ready • RSX runtime initialization failed (\(runtimeResult))")
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // The RSX backend owns frame pacing and drawable acquisition.
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        soulbrandt_runtime_shutdown()
        if let layer = uiView.layer as? CAMetalLayer {
            soulbrandt_metal_layer_clear(Unmanaged.passUnretained(layer).toOpaque())
        }
    }
}
