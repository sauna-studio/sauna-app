// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SaunaAppleSession",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "SaunaAppleSession", targets: ["SaunaAppleSession"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
    ],
    targets: [
        .target(name: "SaunaAppleSession", dependencies: [
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ]),
        .testTarget(name: "SaunaAppleSessionTests", dependencies: ["SaunaAppleSession"]),
    ],
    swiftLanguageModes: [.v6]
)
