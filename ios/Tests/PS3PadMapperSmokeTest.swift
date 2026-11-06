import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \\(message)\\n", stderr)
        exit(1)
    }
}

let neutral = PS3PadMapper.make(snapshot: ControllerInputSnapshot())
expect(neutral.buttons == 0, "neutral buttons")
expect(neutral.leftX == 128 && neutral.leftY == 128, "neutral left stick")

let all = ControllerInputSnapshot(
    leftX: -1, leftY: 1, rightX: 1, rightY: -1,
    leftTrigger: 1, rightTrigger: 0.75,
    buttonA: true, buttonB: true, buttonX: true, buttonY: true,
    leftShoulder: true, rightShoulder: true,
    leftThumbstickButton: true, rightThumbstickButton: true,
    menuButton: true, selectButton: true,
    dpadX: -1, dpadY: 1
)
let mapped = PS3PadMapper.make(snapshot: all)
for button in [PS3PadButton.select, .l3, .r3, .start, .up, .left, .l2, .r2,
               .l1, .r1, .triangle, .circle, .cross, .square] {
    expect(mapped.isPressed(button), "button bit \\(button)")
}
expect(mapped.leftX == 1 && mapped.leftY == 1, "left stick extrema")
expect(mapped.rightX == 255 && mapped.rightY == 255, "right stick extrema")
expect(mapped.analogL2 == 255 && mapped.analogR2 == 191, "trigger pressure")

let released = PS3PadMapper.make(snapshot: ControllerInputSnapshot(
    leftTrigger: 0.49, rightTrigger: 0.49
))
expect(!released.isPressed(.l2) && !released.isPressed(.r2), "trigger digital threshold")
expect(released.analogL2 == 125 && released.analogR2 == 125, "trigger analogue values")

print("PS3 controller mapping smoke test passed")
