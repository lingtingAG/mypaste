// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyPaste",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyPaste", targets: ["MyPaste"]),
        .executable(name: "MyPasteSnapshots", targets: ["MyPasteSnapshots"]),
    ],
    targets: [
        .target(
            name: "MyPasteCore",
            path: "Sources/MyPasteCore",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .target(
            name: "MyPasteUI",
            dependencies: ["MyPasteCore"],
            path: "Sources/MyPasteUI",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "MyPaste",
            dependencies: ["MyPasteUI"],
            path: "Sources/MyPaste"
        ),
        .executableTarget(
            name: "MyPasteSnapshots",
            dependencies: ["MyPasteUI", "MyPasteCore"],
            path: "Sources/MyPasteSnapshots"
        ),
        .testTarget(
            name: "MyPasteTests",
            dependencies: ["MyPasteCore"],
            path: "Tests/MyPasteTests"
        ),
        .testTarget(
            name: "MyPasteUITests",
            dependencies: ["MyPasteUI", "MyPasteCore"],
            path: "Tests/MyPasteUITests"
        ),
    ]
)
