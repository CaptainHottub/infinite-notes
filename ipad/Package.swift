// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "InfiniteNotesStrokeLab",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "InfiniteNotesStrokeLab",
            targets: ["InfiniteNotesStrokeLab"]
        )
    ],
    targets: [
        .target(
            name: "InfiniteNotesStrokeLab",
            path: "Sources/InfiniteNotesStrokeLab"
        )
    ],
    swiftLanguageVersions: [.v5]
)
