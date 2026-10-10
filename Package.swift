// swift-tools-version: 6.0
import PackageDescription
import Foundation

struct AppConfiguration: Decodable { let name: String }
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf:
    root.appendingPathComponent("Sources/TickRestCore/Resources/AppIdentity.json")))
let appName = configuration.name
// Module names are stable implementation identifiers, independent of the product name.
let coreTarget = "TickRestCore"
let appTarget = "TickRestApp"

let package = Package(
    name: appName,
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: appName, targets: [appTarget])],
    targets: [
        .target(name: coreTarget, path: "Sources/TickRestCore", resources: [.process("Resources")]),
        .executableTarget(name: appTarget, dependencies: [.byName(name: coreTarget)], path: "Sources/TickRestApp"),
        .testTarget(name: "\(coreTarget)Tests", dependencies: [.byName(name: coreTarget)], path: "Tests/TickRestCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
