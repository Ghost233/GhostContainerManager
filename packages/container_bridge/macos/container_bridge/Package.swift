// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "container_bridge",
    platforms: [
        // ContainerAPIClient requires macOS 15+; the app targets macOS 26+.
        .macOS("15.0")
    ],
    products: [
        .library(name: "container-bridge", targets: ["container_bridge"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Pinned per docs/research/bridge-flutter-apple-container.md and the
        // runtime gate anchor (docs/spec/onboarding.md): container 1.6.0.
        .package(url: "https://github.com/apple/container.git", exact: "1.6.0")
    ],
    targets: [
        .target(
            name: "container_bridge",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "ContainerAPIClient", package: "container")
            ],
            resources: [
                // If your plugin requires a privacy manifest, for example if it collects user
                // data, update the PrivacyInfo.xcprivacy file to describe your plugin's
                // privacy impact, and then uncomment these lines. For more information, see
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                // .process("PrivacyInfo.xcprivacy"),

                // If you have other resources that need to be bundled with your plugin, refer to
                // the following instructions to add them:
                // https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
            ]
        )
    ]
)
