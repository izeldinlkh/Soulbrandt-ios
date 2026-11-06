import Combine
import Foundation
import GameController

struct ControllerInputSnapshot: Equatable {
    var leftX: Float = 0
    var leftY: Float = 0
    var rightX: Float = 0
    var rightY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var buttonA = false
    var buttonB = false
    var buttonX = false
    var buttonY = false
    var leftShoulder = false
    var rightShoulder = false
    var leftThumbstickButton = false
    var rightThumbstickButton = false
    var optionsButton = false
    var homeButton = false
    var dpadX: Float = 0
    var dpadY: Float = 0
}

@MainActor
final class ControllerMonitor: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var lastInput = "No controller input yet"
    @Published private(set) var input = ControllerInputSnapshot()

    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            Task { @MainActor in self?.attach(controller) }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConnectedController() }
        })

        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        refreshConnectedController()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func refreshConnectedController() {
        if let controller = GCController.controllers().first {
            attach(controller)
        } else {
            controllerName = nil
            input = ControllerInputSnapshot()
            lastInput = "No controller connected"
        }
    }

    private func attach(_ controller: GCController) {
        controllerName = controller.vendorName ?? "Game Controller"
        guard let pad = controller.extendedGamepad else {
            lastInput = "Connected — standard gamepad profile unavailable"
            input = ControllerInputSnapshot()
            return
        }

        // Publish the current state immediately; do not wait for the next button event.
        input = Self.snapshot(from: pad)
        lastInput = "Controller ready"

        // GCController retains its gamepad and the handler. Capture the pad weakly to
        // avoid a pad -> handler -> pad retain cycle for the lifetime of the device.
        pad.valueChangedHandler = { [weak self, weak pad] _, element in
            guard let pad else { return }
            let snapshot = Self.snapshot(from: pad)
            let description = element.localizedName ?? "Gamepad"
            Task { @MainActor in
                self?.input = snapshot
                self?.lastInput = "Input detected: \(description)"
            }
        }
    }

    private nonisolated static func snapshot(from pad: GCExtendedGamepad) -> ControllerInputSnapshot {
        ControllerInputSnapshot(
            leftX: pad.leftThumbstick.xAxis.value,
            leftY: pad.leftThumbstick.yAxis.value,
            rightX: pad.rightThumbstick.xAxis.value,
            rightY: pad.rightThumbstick.yAxis.value,
            leftTrigger: pad.leftTrigger.value,
            rightTrigger: pad.rightTrigger.value,
            buttonA: pad.buttonA.isPressed,
            buttonB: pad.buttonB.isPressed,
            buttonX: pad.buttonX.isPressed,
            buttonY: pad.buttonY.isPressed,
            leftShoulder: pad.leftShoulder.isPressed,
            rightShoulder: pad.rightShoulder.isPressed,
            leftThumbstickButton: pad.leftThumbstickButton?.isPressed ?? false,
            rightThumbstickButton: pad.rightThumbstickButton?.isPressed ?? false,
            optionsButton: pad.buttonOptions?.isPressed ?? false,
            homeButton: pad.buttonHome?.isPressed ?? false,
            dpadX: pad.dpad.xAxis.value,
            dpadY: pad.dpad.yAxis.value
        )
    }
}
