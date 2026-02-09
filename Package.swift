// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoXcode",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "noxcode", targets: ["noxcode"]),
        .library(name: "NoXcodeKit", targets: ["NoXcodeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "CoreModels",
            dependencies: []
        ),
        .target(
            name: "ProcessRunner",
            dependencies: []
        ),
        .target(
            name: "Simctl",
            dependencies: ["CoreModels", "ProcessRunner"]
        ),
        .target(
            name: "XcodeBuild",
            dependencies: ["CoreModels", "ProcessRunner"]
        ),
        .target(
            name: "ProjectConfig",
            dependencies: ["CoreModels"]
        ),
        .target(
            name: "NoXcodeKit",
            dependencies: [
                "CoreModels",
                "ProcessRunner",
                "Simctl",
                "XcodeBuild",
                "ProjectConfig"
            ]
        ),
        .executableTarget(
            name: "noxcode",
            dependencies: [
                "NoXcodeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "CoreModelsTests",
            dependencies: ["CoreModels"]
        ),
        .testTarget(
            name: "SimctlTests",
            dependencies: ["Simctl"]
        ),
        .testTarget(
            name: "XcodeBuildTests",
            dependencies: ["XcodeBuild"]
        ),
        .testTarget(
            name: "ProjectConfigTests",
            dependencies: ["ProjectConfig"]
        )
    ]
)
