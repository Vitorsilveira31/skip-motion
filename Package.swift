// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "skip-motion",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .macCatalyst(.v16)],
    products: [
        .library(name: "SkipMotion", targets: ["SkipMotion"]),
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.6.2"),
        .package(url: "https://github.com/skiptools/skip-ui.git", from: "1.33.1"),
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.6.0"),
    ],
    targets: [
    .target(name: "SkipMotion", dependencies: [
        .product(name: "SkipUI", package: "skip-ui"),
        .product(name: "Lottie", package: "lottie-ios", condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .macCatalyst]))
    ], plugins: [.plugin(name: "skipstone", package: "skip")]),
    .testTarget(name: "SkipMotionTests", dependencies: [
        "SkipMotion",
        .product(name: "SkipTest", package: "skip")
    ], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)

// The browser build of SwiftUIWeb (https://github.com/Vitorsilveira31/SwiftUIWeb) sets SWIFTUIWEB_EMBEDDED. There the
// same `SkipMotion` product is a web implementation (Sources/SkipMotionWeb) that draws with lottie-web through
// SwiftUIWeb's DOMViewRepresentable, so a view that imports SkipMotion builds for iOS, Android and the web unchanged.
if Context.environment["SWIFTUIWEB_EMBEDDED"] != nil {
    package.platforms = nil
    package.dependencies = [.package(url: "https://github.com/Vitorsilveira31/SwiftUIWeb.git", from: "0.1.39")]
    package.targets = [
        .target(name: "SkipMotion", dependencies: [
            .product(name: "SwiftUIWeb", package: "swiftuiweb"),
            .product(name: "SwiftUIWebWeb", package: "swiftuiweb"),
        ], path: "Sources/SkipMotionWeb"),
    ]
} else if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.dependencies += [.package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.0.0")]
    package.targets.forEach({ target in
        target.dependencies += [.product(name: "SkipFuseUI", package: "skip-fuse-ui")]
    })
    // all library types must be dynamic to support bridging
    package.products = package.products.map({ product in
        guard let libraryProduct = product as? Product.Library else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    })
}
