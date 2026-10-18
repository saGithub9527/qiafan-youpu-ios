// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "QFOrbRenderer",
  platforms: [.iOS(.v15)],
  products: [.library(name: "QFOrbRenderer", targets: ["QFOrbRenderer"])],
  dependencies: [.package(url: "https://github.com/SnapKit/SnapKit.git", exact: "6.0.0")],
  targets: [
    .target(name: "QFOrbRenderer", dependencies: ["SnapKit"],
      resources: [.copy("Web")], linkerSettings: [.linkedFramework("WebKit")])
  ]
)
