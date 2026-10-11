// HCFR Colorimeter for macOS
// Copyright (C) 2026 Jorge Velázquez
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU General Public License version 2 as published by the Free Software Foundation.
// It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
// the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.

import SwiftUI

/// Development use: `HCFRColorimeter --snapshot out.png` renders the window with sample data
/// (a real measurement made with HCFR) and quits, to check the layout without a colorimeter.
/// Also `--report out.pdf`, `--project-roundtrip file.hcfrex` and `--levels-test`.
enum Snapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--levels-test") {
            // Development check: levels to measure with and without Override black (restores the setting)
            let session = Session()
            let original = session.overrideBlack
            for value in [true, false] {
                session.overrideBlack = value
                print("overrideBlack=\(value): \(session.levels.count) values, \(session.levels.first!) to 100")
            }
            session.overrideBlack = original
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let session = Session()
        let sample: [(Int, Double, Double, Double)] = [
            (10, 0.2969, 0.3102, 0.880), (20, 0.3067, 0.3219, 3.126), (30, 0.3096, 0.3241, 7.106),
            (40, 0.3108, 0.3255, 13.674), (50, 0.3114, 0.3262, 26.810), (60, 0.3120, 0.3283, 39.654),
            (70, 0.3125, 0.3290, 55.459), (80, 0.3129, 0.3281, 74.584), (90, 0.3130, 0.3287, 97.720),
            (100, 0.3130, 0.3276, 123.189)]
        if args.contains("--primaries") {
            // Example color run: the standard's exact primaries/secondaries, red 3% low and green shifted
            let w = 120.0
            for p in PatchColor.allCases {
                let r = session.ref.rgbToXYZ.apply(p.rgb)
                var xyz = XYZ(X: r[0] * w, Y: r[1] * w, Z: r[2] * w)
                if p == .red { xyz = xyz.scaled(0.97) }
                if p == .green { xyz.X *= 1.04 }
                session.colorMeasurements[p] = xyz
            }
            session.view = .primariesSecondaries
            session.selectedPatch = args.contains("--level10") ? .green : .red
        }
        if let r = args.firstIndex(of: "--report"), r + 1 < args.count {
            defer { exit(0) }
            for s in [(10, 0.2969, 0.3102, 0.880), (50, 0.3114, 0.3262, 26.810), (100, 0.3130, 0.3276, 123.189)] {
                session.measurements[s.0] = XYZ.fromxyY(x: s.1, y: s.2, Y: s.3)
            }
            if let pdf = Report.makePDF(session) { try? pdf.write(to: URL(fileURLWithPath: args[r + 1])) }
        }
        let maxLevel = args.contains("--partial") ? 50 : args.contains("--empty") ? -1 : 100
        for s in sample where s.0 <= maxLevel { session.measurements[s.0] = XYZ.fromxyY(x: s.1, y: s.2, Y: s.3) }
        session.selectedLevel = args.contains("--level10") ? 10 : max(maxLevel, 10)
        if args.contains("--project-roundtrip") {
            // Save, clear, reopen and compare (development check of .hcfrex files)
            let url = URL(fileURLWithPath: args[i + 1])
            session.projectURL = url
            session.saveProject()
            let saved = session.measurements
            session.newProject()
            session.openProject(url)
            let same = saved.count == session.measurements.count
                && saved.allSatisfy { session.measurements[$0.key] == $0.value }
            print(same ? "ROUNDTRIP OK (\(saved.count) levels, dirty=\(session.isDirty))" : "ROUNDTRIP FAILED")
            print(session.status)
            exit(same ? 0 : 1)
        }
        session.status = "Ready — Display: CRT (Hitachi CM2112MET, Diamond View 1772ie)"
        session.lastMeasure = Date()
        let view = ContentView(session: session, autoConnect: false).frame(width: args.contains("--small") ? 1180 : 1400, height: args.contains("--small") ? 680 : 900)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }
}
