// swift-tools-version: 6.4
import PackageDescription

// A SwiftUIWeb app that plays Lottie animations with SkipMotion, the way an app shares its views with a Skip app:
// `import SwiftUI` maps to SwiftUIWeb, and `import SkipMotion` is the same product as on iOS and Android.
// Web/demo/run.sh builds it next to this checkout of skip-motion (`../skip-motion`).
let package = Package(
  name: "MotionDemo",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/Vitorsilveira31/SwiftUIWeb.git", from: "0.1.49"),
    .package(path: "../skip-motion"),
  ],
  targets: [
    .executableTarget(
      name: "MotionDemo",
      dependencies: [
        .product(name: "SwiftUIWeb", package: "swiftuiweb"),
        .product(name: "SwiftUIWebBrowser", package: "swiftuiweb"),
        .product(name: "SkipMotion", package: "skip-motion"),
      ],
      path: "Sources",
      swiftSettings: [.unsafeFlags(["-module-alias", "SwiftUI=SwiftUIWeb"])]
    )
  ]
)
