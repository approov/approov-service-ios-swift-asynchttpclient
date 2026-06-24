// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// The release tag for this version of ApproovAsyncHTTPClient — "dev" for local/CI builds;
// replaced with the CHANGELOG version by the tag-release CI job at release time (in lock-step
// with the runtime user-property string).
let releaseTAG = "dev"
// SDK package version
let sdkVersion: Version = "3.5.3"
// NOTE: The useMiniSDK flag and miniSDKPath are used for local and CI automated testing only.
// They are not included or used in production releases, which depend exclusively on the real approov-ios-sdk.
let useMiniSDK = ProcessInfo.processInfo.environment["APPROOV_USE_MINI_SDK"] == "1"
let miniSDKPath = ProcessInfo.processInfo.environment["APPROOV_MINI_SDK_PATH"] ?? ""

let approovPackageName = useMiniSDK ? "mini-sdk-ios" : "approov-ios-sdk"
let packagePlatforms: [SupportedPlatform] = useMiniSDK
    ? [
        .iOS(.v13),
        .macOS(.v13),
    ]
    : [
        .iOS(.v13),
    ]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/approov/async-http-client", from: "1.10.2"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.38.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.14.1"),
    .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.19.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.10.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.11.4"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-http-structured-headers.git", from: "1.0.0"),
]

if useMiniSDK {
    // Local Mini-SDK dependency for testing purposes only.
    packageDependencies.append(.package(name: "mini-sdk-ios", path: miniSDKPath))
} else {
    // Production release dependency on the official Approov iOS SDK.
    packageDependencies.append(.package(url: "https://github.com/approov/approov-ios-sdk.git", exact: sdkVersion))
}

var packageTargets: [Target] = [
    .target(
        name: "ApproovAsyncHTTPClient",
        dependencies: [
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            .product(name: "Approov", package: approovPackageName),
            .product(name: "RawStructuredFieldValues", package: "swift-http-structured-headers")
        ],
        exclude: ["util/sig/LICENSE"]
    )
]

if useMiniSDK {
    // Test target for verifying the package locally/CI using the mock Mini-SDK.
    packageTargets.append(
        .testTarget(
            name: "ApproovAsyncHTTPClientMiniSDKTests",
            dependencies: [
                "ApproovAsyncHTTPClient",
                .product(name: "Approov", package: "mini-sdk-ios"),
                .product(name: "MiniSDKTestSupport", package: "mini-sdk-ios")
            ],
            path: "Tests/ApproovAsyncHTTPClientMiniSDKTests"
        )
    )
}

let package = Package(
    name: "ApproovAsyncHTTPClient",
    platforms: packagePlatforms,
    products: [
        .library(
            name: "ApproovAsyncHTTPClient",
            targets: ["ApproovAsyncHTTPClient"]
        )
    ],
    dependencies: packageDependencies,
    targets: packageTargets
)
