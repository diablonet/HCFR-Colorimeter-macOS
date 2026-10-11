// HCFR Colorimeter for macOS
// Copyright (C) 2026 Jorge Velázquez
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU General Public License version 2 as published by the Free Software Foundation.
// It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
// the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.

import SwiftUI

@main
struct ColorimeterApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var session = Session()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        Window("HCFR Colorimeter", id: "main") {
            ContentView(session: session)
                .frame(minWidth: 1180, minHeight: 680)
                .onAppear { AppDelegate.session = session }
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About HCFR Colorimeter") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { session.confirmNewProject = true }
                    .keyboardShortcut("n")
                Button("Open Project…") { session.openProjectDialog() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { session.saveProject() }
                    .keyboardShortcut("s")
                Button("Save Project As…") { session.saveProject(as: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { Report.printReport(session) }
                    .keyboardShortcut("p")
                    .disabled(!session.hasMeasurements)
            }
        }
    }
}

enum AboutPanel {
    static let version = "1.0"
    /// Public repository with this program's complete source code (GPL v2 requirement).
    static let sourceURL = "https://github.com/diablonet/HCFR-Colorimeter-macOS"

    static func show() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6

        let credits = NSMutableAttributedString()
        func add(_ text: String, font: NSFont = body, link: String? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: center,
                                                        .foregroundColor: NSColor.labelColor]
            if let link, let url = URL(string: link) { attrs[.link] = url }
            credits.append(NSAttributedString(string: text, attributes: attrs))
        }
        add("Unofficial macOS port of HCFR, not affiliated with the HCFR project.\n\n", font: bold)
        add("Built from the source code of HCFR Colorimeter for Windows (version 3.5.4.4), "
            + "a free and open-source display calibration program created by the HCFR community "
            + "(homecinema-fr.com). The color calculations follow HCFR's own formulas, and the "
            + "colorimeter drivers and CCSS corrections are the ones included in HCFR.\n\n")
        add("Source code: ")
        add(sourceURL.replacingOccurrences(of: "https://", with: ""), link: sourceURL)
        add("\nHCFR project: ")
        add("github.com/arthur-liberman/hcfr-code", link: "https://github.com/arthur-liberman/hcfr-code")
        add("\nOriginal project: ")
        add("sourceforge.net/projects/hcfr", link: "https://sourceforge.net/projects/hcfr/")
        add("\nColorimeter drivers: ArgyllCMS, Copyright Graeme W. Gill (")
        add("argyllcms.com", link: "https://www.argyllcms.com")
        add(")\nHCFR: Copyright Association Homecinema Francophone and HCFR contributors\n\n")
        add("This program is free software: you can redistribute it and/or modify it under the terms "
            + "of the GNU General Public License version 2. It comes with ABSOLUTELY NO WARRANTY. ")
        add("License", link: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")
        add(" (also in the app: Contents/Resources/LICENSE.txt).")

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "HCFR Colorimeter",
            .applicationVersion: version,
            .version: "1",
            .credits: credits,
        ])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var session: Session?

    /// Double-clicking a .hcfrex file in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            guard let url = urls.first else { return }
            if let session = AppDelegate.session {
                if session.confirmDiscardChanges() { session.openProject(url) }
            } else {
                // Window not ready yet: open it as soon as it is
                try? await Task.sleep(for: .seconds(1))
                if let session = AppDelegate.session { session.openProject(url) }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a meter helper that already stopped must not kill the app
        signal(SIGPIPE, SIG_IGN)
        // Needed when run as a bare binary (swift run) instead of the .app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Ask to save unsaved measurements before quitting.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = AppDelegate.session else { return .terminateNow }
        return session.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }
}
