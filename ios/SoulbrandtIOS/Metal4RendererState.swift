import Metal
import MetalKit

/// Metal 4 submission path for iOS 26+ devices that expose the Metal 4 GPU family.
/// Three allocator slots keep up to three frames in flight without reusing command
/// memory before the GPU has finished consuming it.
@available(iOS 26.0, *)
final class Metal4RendererState {
    private struct FrameSlot {
        let allocator: any MTL4CommandAllocator
        let commandBuffer: any MTL4CommandBuffer
    }

    private let queue: any MTL4CommandQueue
    private let completionEvent: any MTLSharedEvent
    private var slots: [FrameSlot] = []
    private var frameNumber: UInt64 = 0

    init?(device: any MTLDevice) {
        guard let queue = device.makeMTL4CommandQueue(),
              let event = device.makeSharedEvent() else {
            return nil
        }

        var newSlots: [FrameSlot] = []
        for _ in 0..<3 {
            guard let allocator = device.makeCommandAllocator(),
                  let commandBuffer = device.makeCommandBuffer() else {
                return nil
            }
            newSlots.append(FrameSlot(allocator: allocator, commandBuffer: commandBuffer))
        }

        self.queue = queue
        self.completionEvent = event
        self.slots = newSlots
    }

    /// Returns false only when the drawable or a required Metal 4 object is unavailable.
    func draw(in view: MTKView, pipeline: any MTLRenderPipelineState) -> Bool {
        guard let renderPass = view.currentMTL4RenderPassDescriptor,
              let drawable = view.currentDrawable,
              !slots.isEmpty else {
            return false
        }

        let slotIndex = Int(frameNumber % UInt64(slots.count))
        if frameNumber >= UInt64(slots.count) {
            let completedFrame = frameNumber - UInt64(slots.count) + 1
            guard completionEvent.wait(untilSignaledValue: completedFrame, timeoutMS: 1000) else {
                return false
            }
        }

        let slot = slots[slotIndex]
        slot.allocator.reset()
        slot.commandBuffer.beginCommandBuffer(allocator: slot.allocator)

        guard let encoder = slot.commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPass,
            options: []
        ) else {
            slot.commandBuffer.endCommandBuffer()
            return false
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        slot.commandBuffer.endCommandBuffer()

        // Metal 4 separates command submission from drawable presentation.
        queue.waitForDrawable(drawable)
        queue.commit([slot.commandBuffer], options: nil)
        queue.signalDrawable(drawable)
        queue.signalEvent(completionEvent, value: frameNumber + 1)
        drawable.present()

        frameNumber += 1
        return true
    }
}
