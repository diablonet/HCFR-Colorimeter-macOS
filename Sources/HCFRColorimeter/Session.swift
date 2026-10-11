// HCFR Colorimeter for macOS
// Copyright (C) 2026 Jorge Velázquez
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU General Public License version 2 as published by the Free Software Foundation.
// It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
// the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.

import AppKit
import Combine

/// Analysed result for one gray level (table column).
struct StepResult: Identifiable, ColorReading {
    let level: Int
    let xyz: XYZ?
    let targetY: Double?
    let balance: [Double]?
    let rgb: [Double]?
    let cct: Double?
    let gamma: Double?
    let deltaE: Double?
    let deltaxy: Double?
    let lab: [Double]?
    let lch: [Double]?
    let measureRGB: [Int]?
    let referenceRGB: [Int]
    let targetCenter: (x: Double, y: Double)
    var id: Int { level }
    var title: String { "\(level)% White" }
    var bars: [Double]? { balance }
    var targetRange: Double { 0.02 }

    /// `whiteY`: measured 100% white (for gamma). `baseY`: white for Y target, ΔE and Lab — the
    /// measured 100%, or 120 cd/m² until it is measured (as HCFR does in a new project), so ΔE is
    /// shown as values come in.
    init(level: Int, xyz: XYZ?, whiteY: Double?, baseY: Double, ref: CalReference) {
        self.level = level
        self.xyz = xyz
        targetCenter = (ref.white.x, ref.white.y)
        // Until 100% is measured only the 100% column shows its base target (120 cd/m²);
        // once it is measured every level gets its target from the real white.
        targetY = whiteY != nil || level == 100 ? ColorMath.targetY(level: level, whiteY: baseY, ref: ref) : nil
        let code = Int((Reference.grayProp(level) * 255).rounded())
        referenceRGB = [code, code, code]
        guard let xyz else {
            balance = nil; rgb = nil; cct = nil; gamma = nil; deltaE = nil
            deltaxy = nil; lab = nil; lch = nil; measureRGB = nil
            return
        }
        balance = ColorMath.rgbBalance(xyz, ref: ref)
        rgb = ColorMath.rgb(xyz, ref: ref)
        cct = ColorMath.cct(xyz)
        deltaxy = ColorMath.deltaxy(xyz, ref: ref)
        gamma = whiteY.flatMap { ColorMath.pointGamma(xyz, whiteY: $0, level: level) }
        deltaE = ColorMath.grayDeltaE(xyz, whiteY: baseY, ref: ref)
        let l = ColorMath.lab(xyz, whiteY: baseY, white: ref.white)
        lab = l
        lch = ColorMath.lch(l)
        measureRGB = ColorMath.displayRGB(xyz, whiteY: baseY, ref: ref)
    }
}

/// Modal message: confirmation (Yes/No) or pattern instruction (Continue/Cancel).
struct UserPrompt: Identifiable {
    enum Style { case yesNo, continueCancel, position }
    let id = UUID()
    let title: String
    let message: String
    let style: Style
    fileprivate let continuation: CheckedContinuation<Void, Error>
}

@MainActor
final class Session: ObservableObject {
    enum Activity { case idle, measuring, continuous }

    // Settings (remembered between launches)
    private let defaults = UserDefaults.standard
    @Published var standard: ColorStandard { didSet { defaults.set(standard.rawValue, forKey: "standard") } }
    @Published var white: WhitePoint { didSet { defaults.set(white.rawValue, forKey: "white") } }
    @Published var gamma: Double {
        didSet {
            let clamped = min(max(gamma, 1.0), 4.0)
            if clamped != gamma { gamma = clamped; return }
            defaults.set(gamma, forKey: "gamma")
        }
    }
    /// Override black (0 cd/m²): 0 IRE is not measured and black is taken as perfect.
    @Published var overrideBlack: Bool {
        didSet {
            defaults.set(overrideBlack, forKey: "overrideBlack")
            if overrideBlack && selectedLevel == 0 { selectedLevel = 100 }
        }
    }
    @Published var selectedPort: MeterPort?
    /// Display of the colorimeter (built-in or CCSS correction), as in HCFR's sensor settings.
    @Published var correction: MeterCorrection?

    // State
    @Published var ports: [MeterPort] = []
    @Published var meter: ArgyllMeter?
    @Published var connecting = false
    @Published var scanning = false
    @Published var status = "Looking for colorimeters…"
    @Published var activity: Activity = .idle
    @Published var measurements: [Int: XYZ] = [:]
    @Published var selectedLevel: Int = 100
    /// Primary / secondary color measurements (and the White measured with them).
    @Published var colorMeasurements: [PatchColor: XYZ] = [:]
    @Published var selectedPatch: PatchColor = .red
    /// Table shown: gray scale or primaries and secondaries.
    @Published var view: MeasureView = .grayScale
    @Published var lastMeasure: Date?
    @Published var prompt: UserPrompt?
    @Published var errorMessage: String?
    @Published var confirmNewProject = false
    /// Project file currently open/saved (nil = never saved).
    @Published var projectURL: URL?
    /// Measurements changed since the last save/open.
    @Published var isDirty = false

    private var task: Task<Void, Never>?
    private var scanTimer: Timer?
    /// Serial numbers already read, by port name (reading one means opening the meter).
    private var serials: [String: String] = [:]
    /// Port this app has open (it can't be opened again to read its serial).
    private var connectedPortName: String?

    init() {
        standard = defaults.string(forKey: "standard").flatMap(ColorStandard.init(rawValue:)) ?? .sdtv
        white = defaults.string(forKey: "white").flatMap(WhitePoint.init(rawValue:)) ?? .d65
        gamma = defaults.object(forKey: "gamma") as? Double ?? 2.3
        overrideBlack = defaults.object(forKey: "overrideBlack") as? Bool ?? true
    }

    var ref: CalReference { CalReference(standard: standard, white: white, gamma: gamma) }

    /// Levels to measure: 0 IRE only when Override black is off.
    var levels: [Int] { overrideBlack ? Reference.allLevels.filter { $0 > 0 } : Reference.allLevels }

    /// Measured black, used for contrast (none when Override black is on: black = 0 cd/m²).
    var blackY: Double? { overrideBlack ? nil : measurements[0]?.Y }

    var contrast: Double? {
        let w = grayBaseY
        guard let b = blackY else { return overrideBlack ? .infinity : nil }
        return b > 0 ? w / b : .infinity
    }

    var busy: Bool { activity != .idle || connecting }

    /// Measured 100% white.
    var whiteY: Double? { measurements[100]?.Y }

    /// White for Y target and ΔE: the measured 100%, or the 120 cd/m² base until it is measured.
    var grayBaseY: Double { whiteY ?? baseWhiteY }

    /// White for the color patches: the White of the color run, else the gray scale 100%, else 120.
    var colorWhiteY: Double { colorMeasurements[.white]?.Y ?? whiteY ?? baseWhiteY }

    /// Measurement of a patch; White falls back to the gray scale 100% if no color run measured it.
    func patchXYZ(_ patch: PatchColor) -> XYZ? {
        colorMeasurements[patch] ?? (patch == .white ? measurements[100] : nil)
    }

    var patchResults: [PatchResult] {
        PatchColor.allCases.map { PatchResult(patch: $0, xyz: patchXYZ($0), whiteY: colorWhiteY, ref: ref) }
    }

    var selectedPatchResult: PatchResult {
        PatchResult(patch: selectedPatch, xyz: patchXYZ(selectedPatch), whiteY: colorWhiteY, ref: ref)
    }

    /// Average / max ΔE of the measured primaries and secondaries (White excluded).
    var colorDeltaEs: [Double] { patchResults.filter { $0.patch != .white }.compactMap(\.deltaE) }

    /// The reading shown in "Selected color" for the current view.
    var selectedReading: ColorReading { view == .grayScale ? selectedResult : selectedPatchResult }

    var hasMeasurements: Bool { !measurements.isEmpty || !colorMeasurements.isEmpty }

    var results: [StepResult] {
        Reference.allLevels.map { result(for: $0) }
    }

    var selectedResult: StepResult { result(for: selectedLevel) }

    private func result(for level: Int) -> StepResult {
        let xyz = level == 0 && overrideBlack ? nil : measurements[level]
        return StepResult(level: level, xyz: xyz, whiteY: whiteY, baseY: grayBaseY, ref: ref)
    }

    /// Average gamma as HCFR (ComputeGammaAndOffset): levels 10% to 80%.
    var averageGamma: Double? {
        let g = results.filter { $0.level >= 10 && $0.level <= 80 }.compactMap(\.gamma)
        return g.isEmpty ? nil : g.reduce(0, +) / Double(g.count)
    }

    var deltaEs: [Double] { results.compactMap(\.deltaE) }
    var averageDeltaE: Double? { deltaEs.isEmpty ? nil : deltaEs.reduce(0, +) / Double(deltaEs.count) }
    var maxDeltaE: Double? { deltaEs.max() }

    // MARK: - Colorimeter

    /// Looks for colorimeters now and keeps checking every few seconds while none is connected,
    /// so a meter plugged in after launch is picked up.
    func startScanning() {
        searchForMeters()
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.meter == nil, !self.busy, !self.scanning, self.prompt == nil else { return }
                self.searchForMeters(quiet: true)
            }
        }
    }

    func searchForMeters(quiet: Bool = false) {
        guard !scanning else { return }
        scanning = true
        Task {
            defer { scanning = false }
            do {
                let found = try await ArgyllMeter.listPorts(knownSerials: serials,
                                                            skipIdentify: Set([connectedPortName].compactMap { $0 }))
                for p in found { if let sn = p.serial, !sn.isEmpty { serials[p.name] = sn } }
                let changed = found != ports
                ports = found
                if let sel = selectedPort {
                    selectedPort = found.first { $0 == sel }   // keep selection, with its serial
                }
                if found.isEmpty {
                    if meter == nil { status = "No colorimeter found. Plug one in — it will be detected automatically." }
                } else if found.count == 1 {
                    if selectedPort == nil { selectedPort = found[0] }
                    if meter == nil { connect() }
                } else if meter == nil && (changed || !quiet) {
                    status = "\(found.count) colorimeters found — choose one in Sensor and press Connect."
                    if selectedPort == nil { selectedPort = found.first }
                } else if !quiet {
                    status = "\(found.count) colorimeters found."
                }
            } catch {
                if !quiet { errorMessage = error.localizedDescription }
            }
        }
    }

    func connect() {
        guard let port = selectedPort else {
            errorMessage = "Choose a colorimeter first."
            return
        }
        guard activity == .idle else { return }
        meter?.close()
        meter = nil
        connectedPortName = nil
        correction = nil
        connecting = true
        status = "Connecting to \(port.displayName)…"
        Task {
            defer { connecting = false }
            do {
                let m = try await ArgyllMeter.open(port: port)
                connectedPortName = port.name
                if !m.serial.isEmpty {
                    serials[port.name] = m.serial
                    if let i = ports.firstIndex(of: port) { ports[i].serial = m.serial }
                    selectedPort?.serial = m.serial
                }
                // Last Display used, or HCFR's CRT correction the first time
                let saved = defaults.string(forKey: "display")
                let pick = m.corrections.first { $0.name == saved }
                    ?? m.corrections.first { $0.isCCSS && $0.name.hasPrefix("CRT") }
                    ?? m.corrections.first
                if let pick { try await m.setCorrection(pick) }
                meter = m
                correction = pick
                status = "Check the meter position…"
                // Like HCFR for Windows: don't go on while the meter is in the wrong position
                do {
                    try await ensurePosition(m)
                } catch {
                    m.close()
                    meter = nil
                    connectedPortName = nil
                    correction = nil
                    status = "Not connected — the meter was left in the wrong position"
                    return
                }
                status = "Ready — Display: \(pick?.name ?? "default")"
            } catch {
                status = "Colorimeter not connected"
                errorMessage = error.localizedDescription
            }
        }
    }

    func setCorrection(_ c: MeterCorrection) {
        guard let meter, activity == .idle, c != correction else { return }
        Task {
            do {
                try await meter.setCorrection(c)
                correction = c
                defaults.set(c.name, forKey: "display")
                status = "Display: \(c.name)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Actions

    func newProject() {
        stop()
        measurements.removeAll()
        colorMeasurements.removeAll()
        lastMeasure = nil
        selectedLevel = 100
        selectedPatch = .red
        projectURL = nil
        isDirty = false
        status = meter == nil ? "Colorimeter not connected" : "New project — ready to measure"
    }

    /// Measure button: runs the chosen test.
    func measure(_ kind: MeasureKind = .grayScale) {
        let grayCount = kind == .grayScale || kind == .grayScaleAndColors ? levels.count : 0
        // As HCFR for Windows, color tests never measure Black (with or without Override black)
        let total = grayCount + kind.patches.count
        var what: [String] = []
        if grayCount > 0 { what.append("\(levels.first!) to 100 IRE") }
        if !kind.patches.isEmpty { what.append(kind.patches.map(\.rawValue).joined(separator: ", ")) }

        view = kind.patches.isEmpty || grayCount > 0 ? .grayScale : .primariesSecondaries
        run(.measuring) {
            try await self.ask("On measure", """
                Run \(kind.title.lowercased()) measures on \(total) values (\(what.joined(separator: "; ")))?
                Warning: current data will be lost.

                Note: you can cancel measuring using the ESC key.
                """, style: .yesNo)
            self.isDirty = true
            if grayCount > 0 {
                self.measurements.removeAll()
                try await self.measureGrayLevels()
            }
            if !kind.patches.isEmpty {
                self.colorMeasurements.removeAll()
                self.view = .primariesSecondaries
                try await self.measurePatches(kind.patches)
            }
            self.status = "\(kind.title) measurement finished"
            Chime.finished()
        }
    }

    /// Grey scale: 10%–100% (0% too without Override black), asking for each pattern.
    private func measureGrayLevels() async throws {
        for level in levels {
            try Task.checkCancellation()
            selectedLevel = level
            try await askPattern("\(level) IRE")
            status = "Measuring \(level) IRE…"
            store(try await readWithCalibration(pattern: "\(level) IRE"), level: level)
        }
        selectedLevel = 100
    }

    /// Colors at 100% in HCFR's order (MeasurePrimaries / MeasureSecondaries / MeasureGrayScaleAndColors).
    private func measurePatches(_ patches: [PatchColor]) async throws {
        for patch in patches {
            try Task.checkCancellation()
            selectedPatch = patch
            let pattern = Self.patternName(patch)
            try await askPattern(pattern)
            status = "Measuring \(patch.rawValue)…"
            colorMeasurements[patch] = try await readWithCalibration(pattern: pattern)
            lastMeasure = Date()
        }
        selectedPatch = .red
    }

    private static func patternName(_ patch: PatchColor) -> String {
        patch == .white ? "100% White (100 IRE)" : "100% \(patch.rawValue)"
    }

    /// Start: continuous reading of the selected column (gray level or color). Clicking another
    /// column switches what is being measured without stopping.
    func start() {
        if view == .grayScale && !levels.contains(selectedLevel) { selectedLevel = 100 }
        run(.continuous) {
            while !Task.isCancelled {
                if self.view == .grayScale {
                    let level = self.selectedLevel
                    self.status = "Continuous reading at \(level) IRE — click another column to measure it, Stop to finish"
                    let xyz = try await self.readWithCalibration(pattern: "\(level) IRE")
                    // If the column changed during the reading, it belongs to the previous pattern: drop it.
                    if self.view == .grayScale && level == self.selectedLevel { self.store(xyz, level: level) }
                } else {
                    let patch = self.selectedPatch
                    self.status = "Continuous reading of \(patch.rawValue) — click another column to measure it, Stop to finish"
                    let xyz = try await self.readWithCalibration(pattern: Self.patternName(patch))
                    if self.view == .primariesSecondaries && patch == self.selectedPatch {
                        self.colorMeasurements[patch] = xyz
                        self.lastMeasure = Date()
                        self.isDirty = true
                    }
                }
            }
        }
    }

    func select(patch: PatchColor) {
        guard activity != .measuring else { return }
        selectedPatch = patch
    }

    func select(level: Int) {
        guard levels.contains(level), activity != .measuring else { return }
        selectedLevel = level
    }

    func stop() {
        task?.cancel()
        // A reading in progress can't be interrupted; if it hasn't finished 5 s after Stop/Cancel/ESC
        // (e.g. the driver hung), restart the meter so the app never stays blocked.
        if let running = task, let m = meter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if self.task == running, self.meter === m { m.abort(reason: "Measurement cancelled") }
            }
        }
        if let p = prompt {
            prompt = nil
            p.continuation.resume(throwing: CancellationError())
        }
    }

    func answerPrompt(proceed: Bool) {
        guard let p = prompt else { return }
        prompt = nil
        if proceed { p.continuation.resume() } else { p.continuation.resume(throwing: CancellationError()) }
    }

    // MARK: - Measuring

    private func store(_ xyz: XYZ, level: Int) {
        measurements[level] = xyz
        lastMeasure = Date()
        isDirty = true
    }

    private func run(_ kind: Activity, _ body: @escaping @MainActor () async throws -> Void) {
        guard meter != nil else {
            errorMessage = "Connect a colorimeter first. This program needs a colorimeter to measure."
            return
        }
        guard task == nil else { return }
        activity = kind
        task = Task {
            do {
                try await body()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                if cancelled {
                    status = "Measurement stopped"
                } else {
                    errorMessage = error.localizedDescription
                    status = "Measurement error"
                }
                // The meter helper died, or was stopped because it hung: reconnect automatically
                if let m = meter, !m.isAlive {
                    meter = nil
                    connectedPortName = nil
                    activity = .idle
                    task = nil
                    if !cancelled {
                        errorMessage = error.localizedDescription
                            + "\n\nThe colorimeter is being reconnected. Your measurements are kept; measure again the step that failed."
                    }
                    connect()
                    return
                }
            }
            activity = .idle
            task = nil
        }
    }

    private func askPattern(_ pattern: String) async throws {
        Chime.request()
        try await ask("Information", "Use \(pattern) and press Continue.", style: .continueCancel)
    }

    private func readWithCalibration(pattern: String) async throws -> XYZ {
        guard let meter else { throw MeterError.failed("Colorimeter not connected") }
        while true {
            try Task.checkCancellation()
            do {
                return try await meter.read()
            } catch MeterError.needsCalibration(let cond, let msg) {
                try await calibrate(meter: meter, condition: cond, message: msg)
                try await askPattern(pattern)
            } catch MeterError.incorrectPosition(let msg) {
                try await ask("Incorrect Position", msg, style: .position)
            }
        }
    }

    /// Repeats the "Incorrect Position" message until the meter is in display measurement position.
    private func ensurePosition(_ meter: ArgyllMeter) async throws {
        while true {
            do {
                try await meter.checkPosition()
                return
            } catch MeterError.incorrectPosition(let msg) {
                try await ask("Incorrect Position", msg, style: .position)
            }
        }
    }

    private func calibrate(meter: ArgyllMeter, condition: UInt32, message: String) async throws {
        var cond = condition, msg = message
        while true {
            // 0x100 = 100% white patch, 0x200 = 80% patch (CRT refresh rate)
            var text = msg
            if cond & 0xFF00 == 0x100 { text = "Use 100 IRE.\n\n" + msg }
            if cond & 0xFF00 == 0x200 { text = "Use 80 IRE (the colorimeter measures the CRT refresh rate).\n\n" + msg }
            try await ask("Colorimeter calibration", text, style: .continueCancel)
            do {
                try await meter.calibrate()
                return
            } catch MeterError.needsCalibration(let c, let m) {
                cond = c; msg = m
            }
        }
    }

    private func ask(_ title: String, _ message: String, style: UserPrompt.Style) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            prompt = UserPrompt(title: title, message: message, style: style, continuation: c)
        }
    }
}

/// Soft sounds: one when the app asks for a pattern, one when a measurement run finishes.
@MainActor
enum Chime {
    private static let requestSound = sound("Tink", volume: 0.35)
    private static let finishedSound = sound("Glass", volume: 0.3)

    private static func sound(_ name: String, volume: Float) -> NSSound? {
        let s = NSSound(named: NSSound.Name(name))
        s?.volume = volume
        return s
    }

    static func request() { requestSound?.stop(); requestSound?.play() }
    static func finished() { finishedSound?.stop(); finishedSound?.play() }
}
