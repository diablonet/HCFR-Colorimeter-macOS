// HCFR Colorimeter for macOS
// Copyright (C) 2026 Jorge Velázquez
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU General Public License version 2 as published by the Free Software Foundation.
// It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
// the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.

import AppKit

/// A pattern to show (or ask for): a gray level in IRE or a 100% color patch.
enum TestPattern: Equatable {
    case gray(Int)
    case color(PatchColor)

    /// Text used in the "Use … and press Continue" message of the manual (DVD) generator.
    var manualName: String {
        switch self {
        case .gray(let level): return "\(level) IRE"
        case .color(.white): return "100% White (100 IRE)"
        case .color(let p): return "100% \(p.rawValue)"
        }
    }

    /// Signal level (0…1) of each channel, before the video range is applied.
    var rgb: [Double] {
        switch self {
        case .gray(let level): return Array(repeating: Double(level) / 100, count: 3)
        case .color(let p): return p.rgb
        }
    }
}

/// Where patterns come from: the user's DVD / external generator, a display of this Mac (full
/// screen), or a movable measurement window.
enum PatternSource: Hashable {
    case manual
    case display(CGDirectDisplayID)
    case window
}

/// Output levels of the built-in generator (as HCFR's GDI generator option).
enum VideoLevels: String, CaseIterable, Identifiable {
    case full = "PC levels (0–255)"
    case video = "Video levels (16–235)"
    var id: String { rawValue }

    /// 8-bit code for a signal level 0…1, rounded like HCFR's GDI generator.
    func code(_ v: Double) -> Int {
        switch self {
        case .full: return Int((v * 255).rounded())
        case .video: return Int((16 + v * 219).rounded())
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Full-screen pattern window on the chosen display. Colors are drawn in the display's own color
/// space so macOS color management does not change the RGB values sent to the screen.
@MainActor
final class PatternWindowController {
    private final class PatternWindow: NSWindow {
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
    }

    private final class PatternView: NSView {
        var rgb: [Int] = [0, 0, 0] { didSet { needsDisplay = true } }
        /// Black around a window patch (16 with video levels).
        var background: [Int] = [0, 0, 0] { didSet { needsDisplay = true } }
        /// Share of the screen area covered by the patch (100 = full field), on black.
        var areaPercent: Double = 100 { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            let space = window?.screen?.colorSpace ?? .deviceRGB
            func color(_ c: [Int]) -> NSColor {
                NSColor(colorSpace: space, components: c.map { CGFloat($0) / 255 } + [1], count: 4)
            }
            color(background).setFill()
            bounds.fill()
            let k = sqrt(min(max(areaPercent, 1), 100) / 100)
            let w = bounds.width * k, h = bounds.height * k
            color(rgb).setFill()
            NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h).fill()
        }
    }

    /// Development check: draws a pattern off screen at 1x in device RGB (as the real window draws
    /// in the display's own color space, without conversion) and returns center and corner pixels.
    static func renderTest(rgb: [Int], areaPercent: Double) -> (center: [Int], corner: [Int]) {
        let size = NSSize(width: 200, height: 100)
        let v = PatternView(frame: NSRect(origin: .zero, size: size))
        v.rgb = rgb
        v.areaPercent = areaPercent
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        func px(_ x: Int, _ y: Int) -> [Int] {
            var p = [Int](repeating: 0, count: 4)
            rep.getPixel(&p, atX: x, y: y)
            return Array(p.prefix(3))
        }
        return (px(100, 50), px(2, 2))
    }

    private var window: PatternWindow?
    private var view: PatternView?
    private var windowed = false
    private var observers: [NSObjectProtocol] = []
    var onEscape: (() -> Void)?

    var isShowing: Bool { window != nil }
    var screen: NSScreen? { window?.screen }

    /// Full-screen pattern on `screen`.
    func show(rgb: [Int], background: [Int] = [0, 0, 0], areaPercent: Double, on screen: NSScreen) {
        if window == nil || windowed || window?.screen != screen {
            close()
            let w = PatternWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                                  defer: false, screen: screen)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            install(w, screen: screen, background: background)
            w.setFrame(screen.frame, display: true)
            // On the app's own screen the pattern covers the app: make it key so ESC stops
            if screen == NSApp.mainWindow?.screen { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
            windowed = false
        }
        update(rgb: rgb, background: background, areaPercent: areaPercent)
    }

    /// Pattern in a normal, movable and resizable "measurement window" (as HCFR's test window),
    /// so the app stays visible. It remembers its place; closing it stops the measurement.
    func showWindowed(rgb: [Int], background: [Int] = [0, 0, 0], areaPercent: Double) {
        if window == nil || !windowed {
            close()
            let screen = NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let size = NSSize(width: 480, height: 360)
            let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let w = PatternWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            w.title = "HCFR Colorimeter — Measurement window (place the meter here)"
            w.level = .floating
            w.minSize = NSSize(width: 160, height: 120)
            install(w, screen: screen, background: background)
            w.setFrameAutosaveName("HCFRMeasurementWindow")
            w.orderFrontRegardless()
            windowed = true
            // Moved to another display: draw in that display's color space
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak w] _ in
                    MainActor.assumeIsolated {
                        guard let w else { return }
                        w.colorSpace = w.screen?.colorSpace
                        w.contentView?.needsDisplay = true
                    }
                })
            // Closing the window (red button) stops the measurement
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.window != nil else { return }
                        self.forget()
                        self.onEscape?()
                    }
                })
        }
        update(rgb: rgb, background: background, areaPercent: areaPercent)
    }

    private func install(_ w: PatternWindow, screen: NSScreen, background: [Int]) {
        w.isReleasedWhenClosed = false
        w.colorSpace = screen.colorSpace
        w.backgroundColor = NSColor(colorSpace: screen.colorSpace ?? .deviceRGB,
                                    components: background.map { CGFloat($0) / 255 } + [1], count: 4)
        w.onEscape = { [weak self] in self?.onEscape?() }
        let v = PatternView(frame: NSRect(origin: .zero, size: w.contentLayoutRect.size))
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        window = w
        view = v
    }

    private func update(rgb: [Int], background: [Int], areaPercent: Double) {
        view?.areaPercent = areaPercent
        view?.background = background
        view?.rgb = rgb
        view?.displayIfNeeded()
    }

    /// Drops the window without stopping anything (it is already closing).
    private func forget() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
        view = nil
    }

    func close() {
        let w = window
        forget()
        w?.orderOut(nil)
    }
}
