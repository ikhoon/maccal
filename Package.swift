// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "maccal",
    platforms: [.macOS(.v14)], // requestFullAccessToEvents / .fullAccess
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // All logic lives here so it's unit-testable without the @main entry
        // or a live EKEventStore (commands take a CalendarStore protocol).
        .target(name: "maccalCore"),

        // Thin ArgumentParser wiring. The linker flags embed Info.plist into
        // the binary's __TEXT,__info_plist section — a bundle-less CLI has no
        // Info.plist otherwise, and EventKit reads the usage-description keys
        // from there (a missing key hard-crashes the process on macOS 14+).
        .executableTarget(
            name: "maccal",
            dependencies: [
                "maccalCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),

        // Menu-bar app: runs `maccal sync` manually or on a launchd schedule.
        // Reuses maccalCore.runSync; the sectcreate flags embed the Calendar
        // usage-description keys the same way as `maccal` (EventKit needs them).
        .executableTarget(
            name: "maccalbar",
            dependencies: ["maccalCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info-maccalbar.plist",
                ]),
            ]
        ),

        // Tests as a plain executable (XCTest / swift-testing ship only with
        // full Xcode; this runs under the Command Line Tools alone via
        // `swift run maccalCheck`, and exits non-zero on any failure).
        .executableTarget(name: "maccalCheck", dependencies: ["maccalCore"]),
    ]
)
