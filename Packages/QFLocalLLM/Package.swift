// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "QFLocalLLM", platforms: [.iOS(.v15)],
  products: [.library(name: "QFLocalLLM", targets: ["QFLocalLLM"])],
  targets: [
    .binaryTarget(name: "QFNativeLlama", path: "Binaries/QFNativeLlama.xcframework"),
    .target(name: "QFLocalLLM", dependencies: ["QFNativeLlama"], publicHeadersPath: "include",
      linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")])
  ], cxxLanguageStandard: .cxx17
)
