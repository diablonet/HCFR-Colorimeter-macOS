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
    /// Spectrometers with high resolution mode: 3.3 nm instead of the standard 10 nm (as HCFR's HiRes).
    @Published var highRes: Bool = false { didSet { defaults.set(highRes, forKey: "highRes") } }
    /// Diagram in the Information panel.
    @Published var infoChart: InfoChart = .balance { didSet { defaults.set(infoChart.rawValue, forKey: "infoChart") } }

    // Pattern generator: the user's DVD / external generator (manual) or a display of this Mac
    @Published var patternSource: PatternSource = .manual { didSet { savePatternSource() } }
    @Published var videoLevels: VideoLevels = .full { didSet { defaults.set(videoLevels.rawValue, forKey: "videoLevels") } }
    /// Patch size on the generator display, % of the screen area (100 = full field).
    @Published var patternArea: Double = 100 { didSet { defaults.set(patternArea, forKey: "patternArea") } }
    /// Wait after showing a pattern before reading, so the display settles.
    @Published var settleSeconds: Double = 1.0 { didSet { defaults.set(settleSeconds, forKey: "settleSeconds") } }
    private let patternWindow = PatternWindowController()
    private var promptPanel: PromptPanelController?
    private var shownPattern: TestPattern?
    @Published var lastMeasure: Date?
    @Published var prompt: UserPrompt?
    /// Prompt waiting for an answer (also while its sheet is being re-presented).
    private var pendingPrompt: UserPrompt?
    /// Prompt whose sheet is actually on screen (set by the sheet itself).
    private var promptOnScreen: UUID?
    /// When the last prompt was answered; a new sheet must wait for the old one to finish closing.
    private var promptClosedAt = Date.distantPast
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
        videoLevels = defaults.string(forKey: "videoLevels").flatMap(VideoLevels.init(rawValue:)) ?? .full
        highRes = defaults.bool(forKey: "highRes")
        infoChart = defaults.string(forKey: "infoChart").flatMap(InfoChart.init(rawValue:)) ?? .balance
        patternArea = defaults.object(forKey: "patternArea") as? Double ?? 100
        settleSeconds = defaults.object(forKey: "settleSeconds") as? Double ?? 1.0
        if defaults.bool(forKey: "patternWindow") {
            patternSource = .window
        } else if let id = defaults.object(forKey: "patternDisplay") as? UInt32,
                  NSScreen.screens.contains(where: { $0.displayID == id }) {
            patternSource = .display(id)
        }
        patternWindow.onEscape = { [weak self] in self?.stop() }
        promptPanel = PromptPanelController(session: self)
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

    /// High resolution checkbox: applied to the connected spectrometer right away.
    func setHighRes(_ on: Bool) {
        guard let meter, meter.supportsHighRes, activity == .idle else { return }
        Task {
            do {
                try await meter.setHighRes(on)
                highRes = on
                status = on ? "High resolution (3.3 nm) on — the meter may ask for a new calibration"
                            : "Standard resolution (10 nm)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The user picked a colorimeter in the list: use it right away (choosing it without pressing
    /// Connect used to keep measuring with the previous meter).
    func choosePort(_ port: MeterPort?) {
        guard let port, port != selectedPort || meter == nil else { return }
        selectedPort = port
        if activity == .idle && !connecting { connect() }
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
                if m.supportsHighRes && highRes { try? await m.setHighRes(true) }
                meter = m
                correction = pick
                status = "Check the meter position…"
                // Like HCFR for Windows: don't go on while the meter is in the wrong position
                // (only on tested meter models; see ArgyllMeter.testedSerialPrefixes)
                do {
                    if m.checksDiffuser { try await ensurePosition(m) }
                } catch {
                    m.close()
                    meter = nil
                    connectedPortName = nil
                    correction = nil
                    status = "Not connected — the meter was left in the wrong position"
                    return
                }
                status = "Ready — Display: \(pick?.name ?? "default")"
                    + (m.checksDiffuser ? "" : " · diffuser position not checked (meter model not tested yet)")
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
            try await present(.gray(level))
            status = "Measuring \(level) IRE…"
            store(try await readWithCalibration(pattern: .gray(level)), level: level)
        }
        selectedLevel = 100
    }

    /// Colors at 100% in HCFR's order (MeasurePrimaries / MeasureSecondaries / MeasureGrayScaleAndColors).
    private func measurePatches(_ patches: [PatchColor]) async throws {
        for patch in patches {
            try Task.checkCancellation()
            selectedPatch = patch
            try await present(.color(patch))
            status = "Measuring \(patch.rawValue)…"
            colorMeasurements[patch] = try await readWithCalibration(pattern: .color(patch))
            lastMeasure = Date()
        }
        selectedPatch = .red
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
                    try await self.showIfGenerator(.gray(level))
                    let xyz = try await self.readWithCalibration(pattern: .gray(level))
                    // If the column changed during the reading, it belongs to the previous pattern: drop it.
                    if self.view == .grayScale && level == self.selectedLevel { self.store(xyz, level: level) }
                } else {
                    let patch = self.selectedPatch
                    self.status = "Continuous reading of \(patch.rawValue) — click another column to measure it, Stop to finish"
                    try await self.showIfGenerator(.color(patch))
                    let xyz = try await self.readWithCalibration(pattern: .color(patch))
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
        closePattern()
        // A reading in progress can't be interrupted; if it hasn't finished 5 s after Stop/Cancel/ESC
        // (e.g. the driver hung), restart the meter so the app never stays blocked.
        if let running = task, let m = meter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if self.task == running, self.meter === m { m.abort(reason: "Measurement cancelled") }
            }
        }
        if let p = pendingPrompt ?? prompt {
            prompt = nil
            pendingPrompt = nil
            promptClosedAt = Date()
            p.continuation.resume(throwing: CancellationError())
        }
    }

    func answerPrompt(proceed: Bool) {
        guard let p = pendingPrompt ?? prompt else { return }
        prompt = nil
        pendingPrompt = nil
        promptClosedAt = Date()
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
            defer { closePattern() }
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

    /// Manual generator: asks the user for the pattern. Built-in generator: shows it on the chosen
    /// display and waits for it to settle.
    private func present(_ pattern: TestPattern) async throws {
        if !generatorActive {
            Chime.request()
            try await ask("Information", "Use \(pattern.manualName) and press Continue.", style: .continueCancel)
        } else {
            try await showIfGenerator(pattern, force: true)
        }
    }

    /// Shows the pattern on the generator display (if one is selected) and waits `settleSeconds`
    /// when it changed.
    private func showIfGenerator(_ pattern: TestPattern, force: Bool = false) async throws {
        guard generatorActive else { return }
        if force || pattern != shownPattern || !patternWindow.isShowing {
            let black = videoLevels.code(0)
            let rgb = pattern.rgb.map { videoLevels.code($0) }
            if let screen = patternScreen {
                patternWindow.show(rgb: rgb, background: [black, black, black], areaPercent: patternArea, on: screen)
            } else {
                let opening = !patternWindow.isShowing
                patternWindow.showWindowed(rgb: rgb, background: [black, black, black], areaPercent: patternArea)
                // A newly opened measurement window must first be placed under the meter
                if opening {
                    Chime.request()
                    try await ask("Measurement window",
                                  "Move the measurement window to the screen you are measuring (and resize it if you want), "
                                  + "place the meter on it, then press Continue to start measuring.",
                                  style: .continueCancel)
                }
            }
            shownPattern = pattern
            try await Task.sleep(for: .seconds(settleSeconds))
        }
    }

    private func closePattern() {
        patternWindow.close()
        shownPattern = nil
    }

    /// Display used as pattern generator, nil for the manual (DVD) generator or if it was disconnected.
    /// True when the app shows the patterns itself (full screen on a display, or the measurement window).
    var generatorActive: Bool { patternSource == .window || patternScreen != nil }

    var patternScreen: NSScreen? {
        guard case .display(let id) = patternSource else { return nil }
        return NSScreen.screens.first { $0.displayID == id }
    }

    /// Displays that can be used as generator: all screens, the one with the app window last.
    var generatorScreens: [NSScreen] {
        let appScreen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: { $0.isVisible })?.screen
        return NSScreen.screens.sorted { a, _ in a != appScreen }
    }

    func screenName(_ screen: NSScreen) -> String {
        let n = (NSScreen.screens.firstIndex(of: screen) ?? 0) + 1
        let appScreen = NSApp.mainWindow?.screen
        return "Display \(n): \(screen.localizedName)" + (screen == appScreen ? " (this window)" : "")
    }

    private func savePatternSource() {
        if case .display(let id) = patternSource { defaults.set(id, forKey: "patternDisplay") }
        else { defaults.removeObject(forKey: "patternDisplay") }
        defaults.set(patternSource == .window, forKey: "patternWindow")
        closePattern()
    }

    private func readWithCalibration(pattern: TestPattern) async throws -> XYZ {
        guard let meter else { throw MeterError.failed("Colorimeter not connected") }
        while true {
            try Task.checkCancellation()
            do {
                return try await meter.read()
            } catch MeterError.needsCalibration(let cond, let msg) {
                try await calibrate(meter: meter, condition: cond, message: msg)
                try await present(pattern)
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
            // 0x100 = 100% white patch, 0x200 = 80% patch (CRT refresh rate); the built-in
            // generator shows them, with the manual generator the user is asked for them
            var text = msg
            let auto = generatorActive
            if cond & 0xFF00 == 0x100 {
                if auto { try await showIfGenerator(.gray(100)) } else { text = "Use 100 IRE.\n\n" + msg }
            }
            if cond & 0xFF00 == 0x200 {
                if auto { try await showIfGenerator(.gray(80)) }
                else { text = "Use 80 IRE (the colorimeter measures the CRT refresh rate).\n\n" + msg }
            }
            try await ask("Colorimeter calibration", text, style: .continueCancel)
            do {
                try await meter.calibrate()
                // As HCFR: after a calibration that needed the meter somewhere else (e.g. an i1Pro
                // on its white tile, or a cap on the sensor), ask to put it back on the screen.
                let needsPlacement = cond & 0xFF00 != 0x100 && cond & 0xFF00 != 0x200
                if needsPlacement {
                    try await ask("Calibration complete",
                                  "The device is now calibrated. If the device requires it, return it to the measurement position on the screen and press Continue.",
                                  style: .continueCancel)
                }
                return
            } catch MeterError.needsCalibration(let c, let m) {
                cond = c; msg = m
            }
        }
    }

    private func ask(_ title: String, _ message: String, style: UserPrompt.Style) async throws {
        // A pattern covering the app's screen would hide the message
        if patternSource != .window, patternWindow.isShowing, let main = NSApp.mainWindow?.screen,
           patternWindow.screen == main {
            closePattern()
        }
        // SwiftUI drops a sheet presented while the previous one is still closing (e.g. "Use 100%
        // Red" right after answering "Run … measures?"), which left the app waiting for an
        // invisible message. Wait for the closing animation first…
        let sinceClosed = Date().timeIntervalSince(promptClosedAt)
        if sinceClosed < 0.6 { try await Task.sleep(for: .seconds(0.6 - sinceClosed)) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = UserPrompt(title: title, message: message, style: style, continuation: c)
            pendingPrompt = p
            prompt = p
            // …and if it still did not appear, present it again.
            Task { @MainActor in
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    guard self.pendingPrompt?.id == p.id, self.promptOnScreen != p.id else { return }
                    self.prompt = nil
                    try? await Task.sleep(for: .seconds(0.6))
                    guard self.pendingPrompt?.id == p.id, self.promptOnScreen != p.id else { return }
                    self.prompt = p
                }
            }
        }
    }

    /// Called by the prompt sheet when it is on screen.
    func promptDidAppear(_ id: UUID) { promptOnScreen = id }
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
