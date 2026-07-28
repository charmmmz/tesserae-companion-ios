// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TesseraeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TesseraeKit", targets: ["TesseraeKit"]),
    ],
    targets: [
        .target(name: "TesseraeKit"),
        .testTarget(
            name: "TesseraeKitTests",
            dependencies: ["TesseraeKit"]
        ),
    ]
)

