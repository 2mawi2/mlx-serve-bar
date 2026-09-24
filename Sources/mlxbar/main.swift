import AppKit

let args = CommandLine.arguments
if args.count > 1, args[1] == "--selftest" {
    exit(SelfTest.run())
}
if args.count > 1, args[1] == "ctl" {
    exit(CTL.run(Array(args.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
