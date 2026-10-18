// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QFSSE", platforms: [.iOS(.v15), .macOS(.v12)],
 products: [.library(name: "QFSSE", targets: ["QFSSE"])],
 targets: [.target(name: "QFSSE"), .testTarget(name: "QFSSETests", dependencies: ["QFSSE"])])
