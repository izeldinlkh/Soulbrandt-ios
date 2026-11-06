import Combine
import GameController
import Foundation

@MainActor
final class ControllerMonitor: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var lastInput = "No controller input yet"

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
            lastInput = "No controller connected"
        }
    }

    private func attach(_ controller: GCController) {
        controllerName = controller.vendorName ?? "Game Controller"
        guard let pad = controller.extendedGamepad else {
            lastInput = "Connected — standard gamepad profile unavailable"
            return
        }

        pad.valueChangedHandler = { [weak self] _, element in
            let description = element.localizedName ?? "Gamepad"
            Task { @MainActor in self?.lastInput = "Input detected: \(description)" }
        }
    }
}
