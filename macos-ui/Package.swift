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
            name: "DiaCoreFFI",
            path: "Sources/DiaCoreFFI",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "DiaMac",
            dependencies: [
                "DiaCoreFFI",
            ],
            path: "Sources/DiaMac",
            linkerSettings: [
                .unsafeFlags(["-L", "../core/target/release"]),
                .linkedLibrary("dia_core"),
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit")
            ]
        )
    ]
)
