// swift-tools-version: 6.4
import PackageDescription

// Apply compiler policy to our targets; dependency modules keep their own settings.
let appleSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(nil),
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "SaunaAppleSession",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "SaunaAppleSession", targets: ["SaunaAppleSession"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", branch: "main"),
        .package(url: "https://github.com/square/Valet.git", from: "5.0.0"),
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "9.0.0"),
        .package(url: "https://github.com/gohanlon/swift-memberwise-init-macro.git", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/fumoboy007/swift-retry.git", from: "0.2.4"),
        .package(url: "https://github.com/mtj0928/swift-async-operations.git", from: "0.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
    ],
    targets: [
        .target(name: "SaunaAppleSession", dependencies: [
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ], swiftSettings: appleSwiftSettings),
        .testTarget(name: "SaunaAppleSessionTests", dependencies: ["SaunaAppleSession"], swiftSettings: appleSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
