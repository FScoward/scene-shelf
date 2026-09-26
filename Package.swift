// swift-tools-version: 6.0

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .unsafeFlags(["-strict-concurrency=complete"])
]

let package = Package(
    name: "SceneShelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SceneShelfCore", targets: ["SceneShelfCore"]),
        .library(name: "SceneShelfAccessibility", targets: ["SceneShelfAccessibility"]),
        .library(name: "SceneShelfPresentation", targets: ["SceneShelfPresentation"]),
        .executable(name: "SceneShelf", targets: ["SceneShelf"]),
        .executable(name: "SceneShelfCoreTestRunner", targets: ["SceneShelfCoreTestRunner"]),
        .executable(name: "SceneShelfAXFixture", targets: ["SceneShelfAXFixture"]),
        .executable(name: "SceneShelfAXTestRunner", targets: ["SceneShelfAXTestRunner"]),
        .executable(name: "SceneShelfRoundTripTestRunner", targets: ["SceneShelfRoundTripTestRunner"]),
        .executable(name: "SceneShelfP0FourTestRunner", targets: ["SceneShelfP0FourTestRunner"]),
        .executable(name: "SceneShelfPresentationTestRunner", targets: ["SceneShelfPresentationTestRunner"]),
        .executable(name: "SceneShelfPersistenceTestRunner", targets: ["SceneShelfPersistenceTestRunner"]),
        .executable(name: "SceneShelfManagementTestRunner", targets: ["SceneShelfManagementTestRunner"]),
        .executable(name: "SceneShelfSwitchingTestRunner", targets: ["SceneShelfSwitchingTestRunner"])
    ],
    targets: [
        .target(
            name: "SceneShelfCore",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "SceneShelfAccessibility",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "SceneShelfPresentation",
            dependencies: ["SceneShelfCore", "SceneShelfAccessibility"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelf",
            dependencies: ["SceneShelfCore", "SceneShelfAccessibility", "SceneShelfPresentation"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfCoreTestRunner",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfAXFixture",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfAXTestRunner",
            dependencies: ["SceneShelfAccessibility"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfRoundTripTestRunner",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfP0FourTestRunner",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfPresentationTestRunner",
            dependencies: ["SceneShelfCore", "SceneShelfAccessibility", "SceneShelfPresentation"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfPersistenceTestRunner",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfManagementTestRunner",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SceneShelfSwitchingTestRunner",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "SceneShelfCoreTests",
            dependencies: ["SceneShelfCore"],
            swiftSettings: strictConcurrency
        )
    ]
)
