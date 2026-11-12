// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "GrokCore", targets: ["GrokCore"]), .library(name: "GrokUsage", targets: ["GrokUsage"])]
var dependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = ["GrokClient", "GrokUsage"]
#if os(macOS)
dependencies.append(.package(path: "Vendor/SwiftMath"))
coreDependencies.append(.product(name: "SwiftMath", package: "SwiftMath"))
#endif
var targets: [Target] = [
    .target(name: "GrokUsage", resources: [.process("Resources")]),
    .target(name: "GrokClient", path: "Vendor/swift-grok/GrokClient"),
    .target(name: "GrokCore", dependencies: coreDependencies, resources: [.process("Resources")]),
    .testTarget(name: "GrokCoreTests", dependencies: ["GrokCore", "GrokClient", "GrokUsage"], path: "Tests")
]
#if os(macOS)
products.append(.executable(name: "SwiftyGrok", targets: ["SwiftyGrok"]))
targets.append(.executableTarget(name: "SwiftyGrok", dependencies: ["GrokCore"], resources: [.process("Resources"), .copy("GrokIcons.bundle")]))
#endif

let package = Package(
    name: "SwiftyGrok", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: products, dependencies: dependencies, targets: targets, swiftLanguageModes: [.v5]
)
