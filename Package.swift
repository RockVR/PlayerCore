// swift-tools-version:5.7
import Foundation
import PackageDescription
let package = Package(
    name: "PlayerCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v10_15), .macCatalyst(.v13), .iOS(.v13), .tvOS(.v13)],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "PlayerCore",
            // todo clang: warning: using sysroot for 'iPhoneSimulator' but targeting 'MacOSX' [-Wincompatible-sysroot]
//            type: .dynamic,
            targets: ["PlayerCore"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        .target(
            name: "PlayerCore",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
//                .product(name: "Libass", package: "FFmpegKit"),
//                .product(name: "Libmpv", package: "FFmpegKit"),
            ],
            resources: [
                .process("Metal/Shaders.metal"),
                .process("Metal/Meshes/Plane.obj"),
                .process("Metal/Meshes/Dome180.obj"),
                .process("Metal/Meshes/Sphere360.obj"),
                .process("Metal/Meshes/CubeH.obj"),
                .process("Metal/Meshes/CubeV.obj"),
                .process("Metal/Meshes/Fisheye180.obj"),
                .process("Metal/Meshes/Fisheye190.obj"),
                .process("Metal/Meshes/Fisheye200.obj")
            ]
        )
    ]
)
var ffmpegKitPath = FileManager.default.currentDirectoryPath + "/FFmpegKit"
if !FileManager.default.fileExists(atPath: ffmpegKitPath) {
    ffmpegKitPath = FileManager.default.currentDirectoryPath + "../FFmpegKit"
}

if !FileManager.default.fileExists(atPath: ffmpegKitPath) {
    ffmpegKitPath = FileManager.default.currentDirectoryPath + "/PlayerCore/FFmpegKit"
}

if !FileManager.default.fileExists(atPath: ffmpegKitPath), let url = URL(string: #file) {
    let path = url.deletingLastPathComponent().path
    // 解决用xcode引入spm的时候，依赖关系出错的问题
    if !path.contains("/checkouts/") {
        ffmpegKitPath = path + "/FFmpegKit"
    }
}

if FileManager.default.fileExists(atPath: ffmpegKitPath + "/Package.swift") {
    package.dependencies += [
        .package(path: ffmpegKitPath),
    ]
} else {
    package.dependencies += [
        .package(url: "https://github.com/kingslay/FFmpegKit.git", from: "6.1.0"),
    ]
}
