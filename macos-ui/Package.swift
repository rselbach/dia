// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dia",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Dia", targets: ["DiaMac"])
    ],
    targets: [
        .target(
            name: "DiaKit",
            path: "Sources/DiaKit"
        ),
        .executableTarget(
            name: "DiaMac",
            dependencies: ["DiaKit"],
            path: "Sources/DiaMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "DiaKitTests",
            dependencies: ["DiaKit"],
            path: "Tests/DiaKitTests"
        )
    ]
)
