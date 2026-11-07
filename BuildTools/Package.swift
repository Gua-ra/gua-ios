// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BuildTools",
    dependencies: [
        .package(url: "https://github.com/nicklockwood/SwiftFormat", exact: "0.64.3")
    ],
    targets: [
        .target(name: "BuildTools", path: "")
    ]
)
