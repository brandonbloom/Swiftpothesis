// swift-tools-version: 6.2

import PackageDescription

// CI sets SWIFTPOTHESIS_STRICT so warnings fail the build; local builds keep them as warnings while editing.
let strict: [SwiftSetting] =
    Context.environment["SWIFTPOTHESIS_STRICT"] != nil ? [.treatAllWarnings(as: .error)] : []

let package = Package(
    name: "Swiftpothesis",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "Swiftpothesis", targets: ["Swiftpothesis"])
    ],
    targets: [
        .target(name: "Swiftpothesis", swiftSettings: strict),
        .testTarget(
            name: "SwiftpothesisTests", dependencies: ["Swiftpothesis"], swiftSettings: strict),
    ]
)
