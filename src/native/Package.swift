// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "BattOpt",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "BattOpt", targets: ["BattOpt"])
    ],
    targets: [
        .target(
            name: "BattOpt",
            path: "Sources/BattOpt",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
