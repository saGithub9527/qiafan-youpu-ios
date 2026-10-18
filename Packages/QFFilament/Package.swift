// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "QFFilament",
  platforms: [.iOS(.v15)],
  products: [.library(name: "QFFilamentBridge", targets: ["QFFilamentBridge"])],
  targets: [
    .binaryTarget(name: "Native_filament", path: "Binaries/libfilament.xcframework"),
    .binaryTarget(name: "Native_backend", path: "Binaries/libbackend.xcframework"),
    .binaryTarget(name: "Native_filaflat", path: "Binaries/libfilaflat.xcframework"),
    .binaryTarget(name: "Native_filabridge", path: "Binaries/libfilabridge.xcframework"),
    .binaryTarget(name: "Native_utils", path: "Binaries/libutils.xcframework"),
    .binaryTarget(name: "Native_geometry", path: "Binaries/libgeometry.xcframework"),
    .binaryTarget(name: "Native_smol_v", path: "Binaries/libsmol-v.xcframework"),
    .binaryTarget(name: "Native_abseil", path: "Binaries/libabseil.xcframework"),
    .binaryTarget(name: "Native_gltfio_core", path: "Binaries/libgltfio_core.xcframework"),
    .binaryTarget(name: "Native_dracodec", path: "Binaries/libdracodec.xcframework"),
    .binaryTarget(name: "Native_meshoptimizer", path: "Binaries/libmeshoptimizer.xcframework"),
    .binaryTarget(name: "Native_stb", path: "Binaries/libstb.xcframework"),
    .binaryTarget(name: "Native_uberarchive", path: "Binaries/libuberarchive.xcframework"),
    .binaryTarget(name: "Native_uberzlib", path: "Binaries/libuberzlib.xcframework"),
    .binaryTarget(name: "Native_zstd", path: "Binaries/libzstd.xcframework"),
    .binaryTarget(name: "Native_shaders", path: "Binaries/libshaders.xcframework"),
    .binaryTarget(name: "Native_ktxreader", path: "Binaries/libktxreader.xcframework"),
    .binaryTarget(name: "Native_basis_transcoder", path: "Binaries/libbasis_transcoder.xcframework"),
    .target(name: "QFFilamentBridge", dependencies: ["Native_filament", "Native_backend", "Native_filaflat", "Native_filabridge", "Native_utils", "Native_geometry", "Native_smol_v", "Native_abseil", "Native_gltfio_core", "Native_dracodec", "Native_meshoptimizer", "Native_stb", "Native_uberarchive", "Native_uberzlib", "Native_zstd", "Native_shaders", "Native_ktxreader", "Native_basis_transcoder"],
      path: "Sources/QFFilamentBridge", publicHeadersPath: "include",
      cxxSettings: [.headerSearchPath("FilamentHeaders/include")],
      linkerSettings: [.linkedFramework("Metal"), .linkedFramework("MetalKit"),
                       .linkedFramework("QuartzCore"), .linkedFramework("UIKit"),
                       .linkedFramework("Foundation"), .linkedLibrary("c++")])
  ],
  cxxLanguageStandard: .cxx20
)
