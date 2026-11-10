// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TabSwitch",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "TabSwitch", path: "Sources",
        // SkyLight (private) for raising one window without bringing its siblings along
        linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])])]
)
