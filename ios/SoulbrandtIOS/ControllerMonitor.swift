import Combine
import Foundation
import GameController


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
            soulbrandt_pad_state_reset()
            lastInput = "No controller connected"
        }
    }

    private func attach(_ controller: GCController) {
        controllerName = controller.vendorName ?? "Game Controller"
        guard let pad = controller.extendedGamepad else {
            lastInput = "Connected — standard gamepad profile unavailable"
            input = ControllerInputSnapshot()
            soulbrandt_pad_state_reset()
            return
        }

        // Publish the current state immediately; do not wait for the next button event.
        publish(Self.snapshot(from: pad))
        lastInput = "Controller ready"

        // GCController retains its gamepad and the handler. Capture the pad weakly to
        // avoid a pad -> handler -> pad retain cycle for the lifetime of the device.
        pad.valueChangedHandler = { [weak self, weak pad] _, element in
            guard let pad else { return }
            let snapshot = Self.snapshot(from: pad)
            let description = element.localizedName ?? "Gamepad"
            Task { @MainActor in
                self?.publish(snapshot)
                self?.lastInput = "Input detected: \(description)"
            }
        }
    }

    private func publish(_ snapshot: ControllerInputSnapshot) {
        input = snapshot
        let state = PS3PadMapper.make(snapshot: snapshot)
        soulbrandt_pad_state_write(
            1, state.buttons, state.leftX, state.leftY, state.rightX, state.rightY,
            state.analogL2, state.analogR2
        )
    }

    private nonisolated static func selectButtonState(from pad: GCExtendedGamepad) -> Bool {
        if let dualSense = pad as? GCDualSenseGamepad {
            return dualSense.touchpadButton.isPressed
        }
        if let dualShock = pad as? GCDualShockGamepad {
            return dualShock.touchpadButton.isPressed
        }
        // On Xbox and generic extended profiles, Options is the Back/View button.
        return pad.buttonOptions?.isPressed ?? false
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
            menuButton: pad.buttonMenu.isPressed,
            selectButton: selectButtonState(from: pad),
            dpadX: pad.dpad.xAxis.value,
            dpadY: pad.dpad.yAxis.value
        )
    }
}
