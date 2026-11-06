import Foundation

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

enum PS3PadButton: UInt16 {
    case select = 0x0001
    case l3 = 0x0002
    case r3 = 0x0004
    case start = 0x0008
    case up = 0x0010
    case right = 0x0020
    case down = 0x0040
    case left = 0x0080
    case l2 = 0x0100
    case r2 = 0x0200
    case l1 = 0x0400
    case r1 = 0x0800
    case triangle = 0x1000
    case circle = 0x2000
    case cross = 0x4000
    case square = 0x8000
}

struct PS3PadState: Equatable {
    var buttons: UInt16 = 0
    // CELL_PAD's unsigned analog convention: 0x00 negative, 0x80 centre, 0xFF positive.
    var leftX: UInt8 = 0x80
    var leftY: UInt8 = 0x80
    var rightX: UInt8 = 0x80
    var rightY: UInt8 = 0x80
    var analogL2: UInt8 = 0
    var analogR2: UInt8 = 0

    func isPressed(_ button: PS3PadButton) -> Bool {
        buttons & button.rawValue != 0
    }
}

enum PS3PadMapper {
    static func make(snapshot: ControllerInputSnapshot) -> PS3PadState {
        var state = PS3PadState()
        func set(_ button: PS3PadButton, _ pressed: Bool) {
            if pressed { state.buttons |= button.rawValue }
        }

        // Standard GameController face labels follow the Xbox-style positions:
        // A=bottom (Cross), B=right (Circle), X=left (Square), Y=top (Triangle).
        set(.cross, snapshot.buttonA)
        set(.circle, snapshot.buttonB)
        set(.square, snapshot.buttonX)
        set(.triangle, snapshot.buttonY)
        set(.l1, snapshot.leftShoulder)
        set(.r1, snapshot.rightShoulder)
        set(.l2, snapshot.leftTrigger >= 0.5)
        set(.r2, snapshot.rightTrigger >= 0.5)
        set(.l3, snapshot.leftThumbstickButton)
        set(.r3, snapshot.rightThumbstickButton)
        set(.start, snapshot.optionsButton)
        set(.select, snapshot.homeButton)

        let threshold: Float = 0.5
        set(.left, snapshot.dpadX < -threshold)
        set(.right, snapshot.dpadX > threshold)
        set(.up, snapshot.dpadY > threshold)
        set(.down, snapshot.dpadY < -threshold)

        state.leftX = axis(snapshot.leftX)
        state.leftY = axis(-snapshot.leftY)
        state.rightX = axis(snapshot.rightX)
        state.rightY = axis(-snapshot.rightY)
        state.analogL2 = pressure(snapshot.leftTrigger)
        state.analogR2 = pressure(snapshot.rightTrigger)
        return state
    }

    private static func axis(_ value: Float) -> UInt8 {
        let clamped = min(1, max(-1, value))
        return UInt8((128 + clamped * 127).rounded())
    }

    private static func pressure(_ value: Float) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }
}
