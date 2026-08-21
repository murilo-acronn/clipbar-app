// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipBar",
            path: "Sources/ClipBar",
            // v5 mode on purpose: this app is single-threaded around the main
            // run loop, and strict concurrency mostly fights the Carbon and
            // NSPasteboard C APIs without buying us anything here.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("LinkPresentation"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
