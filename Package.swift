// swift-tools-version:5.9
// HCFR Colorimeter for macOS — Copyright (C) 2026 Jorge Velázquez — GNU GPL v2 (see LICENSE)
import PackageDescription

let package = Package(
    name: "HCFRColorimeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HCFRColorimeter", path: "Sources/HCFRColorimeter")
    ]
)
