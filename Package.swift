// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiZhong",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiZhong", targets: ["MiZhong"]),
        .library(name: "DuplicateCore", targets: ["DuplicateCore"])
    ],
    targets: [
        .target(name: "DuplicateCore"),
        .executableTarget(name: "MiZhong", dependencies: ["DuplicateCore"], path: "Sources/FileTwin"),
        .testTarget(name: "DuplicateCoreTests", dependencies: ["DuplicateCore"]),
        .testTarget(name: "MiZhongUITests", dependencies: ["MiZhong", "DuplicateCore"])
    ]
)
