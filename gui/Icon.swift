import AppKit

// Renders a 1024x1024 green-on-black ">_" icon to the path given as argv[1].
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let green = NSColor(red: 0, green: 1, blue: 0, alpha: 1)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSColor.black.setFill(); path.fill()
green.setStroke(); path.lineWidth = 14; path.stroke()
let font = NSFont.monospacedSystemFont(ofSize: 420, weight: .heavy)
let s = NSAttributedString(string: ">_", attributes: [.font: font, .foregroundColor: green])
let ts = s.size()
s.draw(at: NSPoint(x: (CGFloat(size) - ts.width) / 2, y: (CGFloat(size) - ts.height) / 2 + 10))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
