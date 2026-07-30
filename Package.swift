// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "WeChatTweak",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "wechattweak",
            targets: [
                "WeChatTweak"
            ]
        ),
        .library(
            name: "WeChatTweakMenu",
            type: .dynamic,
            targets: [
                "WeChatTweakMenu"
            ]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            exact: "1.2.3"
        )
    ],
    targets: [
        .executableTarget(
            name: "WeChatTweak",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(
            name: "WeChatTweakMenu",
            path: "Sources/WeChatTweakMenu",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "WeChatTweakTests",
            dependencies: ["WeChatTweak"]
        )
    ]
)
