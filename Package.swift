// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SheetFeed",
    platforms: [.macOS(.v14)],
    targets: [
        // Scanner-independent page processing, OCR and export. Unit tested.
        .target(name: "ScanKit"),
        // The macOS app: scanner connection (ImageCaptureCore) and SwiftUI interface.
        .executableTarget(name: "SheetFeed", dependencies: ["ScanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
    ],
    swiftLanguageModes: [.v5]
)
