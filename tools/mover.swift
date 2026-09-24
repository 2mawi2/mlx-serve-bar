// Post a synthetic mouse event at absolute screen coords (top-left origin).
// usage: mover <x> <y> [move|click|rightclick|escape]
import CoreGraphics
import Carbon.HIToolbox

let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let x = Double(args[1])!, y = Double(args[2])!
let kind = args.count > 3 ? args[3] : "move"
let p = CGPoint(x: x, y: y)

func postMove() {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

switch kind {
case "move":
    CGWarpMouseCursorPosition(p)
    CGAssociateMouseAndMouseCursorPosition(1)
    usleep(30_000)
    postMove()
case "click":
    CGWarpMouseCursorPosition(p)
    usleep(50_000)
    postMove()
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
case "rightclick":
    CGWarpMouseCursorPosition(p)
    usleep(50_000)
    postMove()
    CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right)?.post(tap: .cghidEventTap)
case "escape":
    let e = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Escape), keyDown: true)
    e?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Escape), keyDown: false)?.post(tap: .cghidEventTap)
default:
    exit(2)
}
