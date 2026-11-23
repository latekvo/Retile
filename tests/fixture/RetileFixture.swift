// Test app for tests/e2e.lua: opens N resizable windows ("Fixture 1".."Fixture N")
// plus one fixed-size window ("Fixed"), and one more resizable window per SIGUSR1.
// Usage: RetileFixture [N]
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

var windows: [NSWindow] = []
var opened = 0

func open(_ title: String, resizable: Bool) {
  var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
  if resizable { style.insert(.resizable) }
  let offset = CGFloat(windows.count * 40)
  let window = NSWindow(
    contentRect: NSRect(x: 120 + offset, y: 120 + offset, width: 420, height: 280),
    styleMask: style, backing: .buffered, defer: false)
  window.title = title
  window.isReleasedWhenClosed = false
  window.makeKeyAndOrderFront(nil)
  windows.append(window)
}

func openFixture() {
  opened += 1
  open("Fixture \(opened)", resizable: true)
}

let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3
for _ in 1...count { openFixture() }
open("Fixed", resizable: false)

signal(SIGUSR1, SIG_IGN)
let more = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
more.setEventHandler { openFixture() }
more.resume()

app.run()
