// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SaunaAppleSession",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "SaunaAppleSession", targets: ["SaunaAppleSession"])],
    targets: [
        .target(name: "SaunaAppleSession"),
        .testTarget(name: "SaunaAppleSessionTests", dependencies: ["SaunaAppleSession"]),
    ],
    swiftLanguageModes: [.v6]
)
