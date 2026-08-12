import AppKit
import Testing
@testable import MacshotCore

// MARK: - Hotkeys

@Test
func hotkeyConflictsDetected() {
    var settings = HotkeySettings()
    #expect(settings.conflicts().isEmpty, "Default bindings must not conflict")

    settings.window = settings.region
    let conflicts = settings.conflicts()
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.0 == .captureRegion)
    #expect(conflicts.first?.1 == .captureWindow)
}

@Test
func hotkeyBindingAccessorsRoundTrip() {
    var settings = HotkeySettings()
    let binding = HotkeyBinding(keyCode: 99, carbonModifiers: 0x100)
    for action in HotkeyAction.allCases {
        settings.setBinding(binding, for: action)
        #expect(settings.binding(for: action) == binding)
        settings.setBinding(nil, for: action)
        #expect(settings.binding(for: action) == nil)
    }
}

@MainActor
@Test
func carbonModifierConversion() {
    let flags: NSEvent.ModifierFlags = [.control, .shift]
    #expect(HotkeyBinding.carbonModifiers(from: flags) == 0x1200)
    let all: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    #expect(HotkeyBinding.carbonModifiers(from: all) == 0x1200 | 0x800 | 0x100)
}

@MainActor
@Test
func hotkeyDisplayStringShowsModifiersAndKey() {
    let binding = HotkeyBinding(keyCode: 21, carbonModifiers: 0x1200) // ⌃⇧4
    let display = binding.displayString
    #expect(display.hasPrefix("⌃⇧"))
    #expect(display.hasSuffix("4"))

    let escape = HotkeyBinding(keyCode: 53, carbonModifiers: 0)
    #expect(escape.displayString == "⎋")
}

@MainActor
@Test
func hotkeyManagerReappliesCleanly() {
    // Registration success depends on the session (a headless test host can't
    // register system hotkeys), so only assert apply/re-apply consistency.
    let manager = HotkeyManager()
    let failedFirst = manager.apply(HotkeySettings())
    let failedSecond = manager.apply(HotkeySettings())
    #expect(failedFirst == failedSecond)
    manager.unregisterAll()
}

// MARK: - Color formatting

@Test
func colorFormatsAreCorrect() {
    #expect(ColorFormatter.format(r: 58, g: 123, b: 213, as: .hex) == "#3A7BD5")
    #expect(ColorFormatter.format(r: 58, g: 123, b: 213, as: .rgb) == "rgb(58, 123, 213)")
    #expect(ColorFormatter.format(r: 255, g: 255, b: 255, as: .hex) == "#FFFFFF")
    #expect(ColorFormatter.format(r: 0, g: 0, b: 0, as: .hex) == "#000000")
}

@Test
func hslConversionMatchesKnownValues() {
    // Pure red.
    let red = ColorFormatter.hsl(r: 255, g: 0, b: 0)
    #expect(red == (0, 100, 50))
    // Pure green.
    let green = ColorFormatter.hsl(r: 0, g: 255, b: 0)
    #expect(green == (120, 100, 50))
    // White and black are achromatic.
    #expect(ColorFormatter.hsl(r: 255, g: 255, b: 255) == (0, 0, 100))
    #expect(ColorFormatter.hsl(r: 0, g: 0, b: 0) == (0, 0, 0))
    // Mid gray.
    let gray = ColorFormatter.hsl(r: 128, g: 128, b: 128)
    #expect(gray.0 == 0 && gray.1 == 0)
    #expect(abs(gray.2 - 50) <= 1)
}

// MARK: - Pixel sampling

@Test
func pixelBufferSamplesKnownPixels() {
    let width = 8, height = 8
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Bottom-left quadrant red, everything else blue. CGContext origin is
    // bottom-left; PixelBuffer reads top-left.
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = ctx.makeImage()!

    let buffer = PixelBuffer(image: image)!
    // Top-left of the buffer = top of the image = blue.
    let top = buffer.color(x: 1, y: 1)!
    #expect(top.b > 200 && top.r < 50)
    // Bottom-left = red.
    let bottom = buffer.color(x: 1, y: 6)!
    #expect(bottom.r > 200 && bottom.b < 50)
    // Out of bounds is nil.
    #expect(buffer.color(x: -1, y: 0) == nil)
    #expect(buffer.color(x: 8, y: 0) == nil)
}
