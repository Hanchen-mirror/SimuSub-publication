// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimulSubtitleMac",
    platforms: [.macOS("13.3")],
    products: [
        .executable(name: "SimulSubtitleMac", targets: ["SimulSubtitleMac"]),
        .executable(name: "SimuSubRelaunch", targets: ["SimuSubRelaunch"]),
        .executable(name: "SimuSubLiveTool", targets: ["SimuSubLiveTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git", exact: "1.13.8"),
        .package(url: "https://github.com/mattt/llama.swift", exact: "2.10549.0")
    ],
    targets: [
        .executableTarget(name: "SimuSubRelaunch", path: "Sources/SimuSubRelaunch"),
        .executableTarget(name: "SimuSubLiveTool", path: "Sources/SimuSubLiveTool"),
        .executableTarget(
            name: "SimulSubtitleMac",
            dependencies: [
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "LlamaSwift", package: "llama.swift")
            ],
            path: "Sources/SimulSubtitleMac"
        )
    ]
)
