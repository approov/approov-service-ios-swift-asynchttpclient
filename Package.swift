// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let approovSDKVersion = "3.2.2"
let approovSDKChecksum = "37ecded23807af9a9720018201f2e25a43e388cb4d78b15e78cd3f85c6b0682b"
let asyncHTTPClientVersion: Version = Version(1, 10, 2)

let package = Package(
    name: "ApproovAsyncHTTPClient",
    platforms: [.iOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "ApproovAsyncHTTPClient",
            targets: ["ApproovAsyncHTTPClient", "Approov"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/approov/async-http-client", from: asyncHTTPClientVersion),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.38.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.14.1"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.11.4"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "ApproovAsyncHTTPClient",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client")]
                ),
        .binaryTarget(
            name: "Approov",
            url: "https://github.com/approov/approov-ios-sdk/releases/download/" + approovSDKVersion + "/Approov.xcframework.zip",
            checksum : approovSDKChecksum
            ),
    ]
)
