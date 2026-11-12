// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Typeset",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ObjCTry", path: "Sources/ObjCTry"),
        .executableTarget(name: "Typeset", dependencies: ["ObjCTry"], path: "Sources/Typeset")
    ]
)
