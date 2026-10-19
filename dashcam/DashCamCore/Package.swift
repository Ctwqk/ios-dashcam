// swift-tools-version:5.9
import PackageDescription

// Pure, Foundation-only logic extracted from the DashCam app so that it can be
// unit tested without a camera, a simulator or UIKit: rolling-buffer eviction,
// collision thresholding, storage quota policy, file naming and clip metadata.
let package = Package(
    name: "DashCamCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DashCamCore", targets: ["DashCamCore"])
    ],
    targets: [
        .target(name: "DashCamCore"),
        .testTarget(name: "DashCamCoreTests", dependencies: ["DashCamCore"])
    ]
)
