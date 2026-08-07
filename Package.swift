// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "WeChatTweak",
    platforms: [
        .macOS(.v10_15)
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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "WeChatTweak",
            dependencies: []
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
        )
    ]
)
